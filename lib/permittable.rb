# Before active_support: on activesupport <= 7.0.8.4, requiring it raises
# NameError (ActiveSupport::LoggerThreadSafeLevel::Logger) unless `logger` is
# already loaded, because concurrent-ruby 1.3.5 stopped requiring it for them.
# One stdlib require makes `require "permittable"` work on every activesupport
# version the gemspec claims, whatever the host's own boot order.
require "logger"

require "active_support"
require "active_support/concern"
require "active_support/notifications"
require "active_support/hash_with_indifferent_access"
require "active_support/core_ext/hash/indifferent_access" # nested plain Hashes inside HWIA.new
require "active_support/core_ext/class/attribute"
require "active_support/core_ext/object/deep_dup" # authored default:/example: values are copied before freezing
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/string/filters"
# cast_datetime names ActiveSupport::TimeWithZone, which activesupport does not
# load by default. A Rails app has it via active_support/time at boot; a
# standalone host (a Contract validating a webhook payload or a job argument)
# has nothing that loads it, and every :datetime cast raised NameError there.
#
# The Time core extensions come with it, and are not optional: TimeWithZone is
# present but not self-sufficient. Converting one goes through
# TimeZone#utc_to_local, which calls Time#sec_fraction — defined in
# core_ext/time/calculations, which time_with_zone.rb does not itself require.
# Without this line a real TimeWithZone raises NoMethodError in a bare host on
# activesupport 8.1, having merely traded one crash for another.
require "active_support/core_ext/time/calculations"
require "bigdecimal"
require "date"
require "time"
require "uri" # URI::MailTo::EMAIL_REGEXP backs the :email format preset

require "permittable/version"
require "permittable/error_envelope"
require "permittable/column_guard"
require "permittable/filter_parameter_registry"

# Declarative, typed params contracts — what strong parameters would be if it
# also knew types, bounds, defaults, and why a request was bad. Strong
# parameters (and Rails 8's `params.expect`) only answer "which keys may
# pass"; a Permittable contract additionally casts each field, validates it,
# applies defaults, and turns every failure into a machine-readable 422 — and,
# because the contract is class-level data rather than code inside the action,
# it is introspectable (`permittable_contracts`) and can be checked against a
# model's schema at class-load time.
#
#   class UsersController < ApplicationController
#     include Permittable
#
#     permit_params :create, :update, root: :user, model: User do
#       required :name,  :string,  length: 1..80, normalize: :squish
#       required :email, :string,  format: URI::MailTo::EMAIL_REGEXP, normalize: :email
#       optional :age,   :integer, in: 18..120
#       optional :ssn,   :string,  sensitive: true
#       optional :plan,  :string,  in: %w[free pro], default: "free"
#       array    :tag_names, of: :string, length: 0..10, virtual: true
#       optional :metadata,  :json,    max_depth: 3, length: 0..32
#       optional :address do
#         required :city, :string
#         optional :zip,  :string, format: /\A\d{5}\z/
#       end
#     end
#
#     def create
#       user = User.create!(permitted_params) # cast, validated, defaulted
#     end
#   end
#
# THE LAST MATCHING RULE WINS: contracts are configuration, so a base
# controller's catch-all (a rule declared with no actions) is overridden by a
# later action-specific declaration in a subclass. Rules accumulate via
# reassignment, never mutation, so subclasses inherit copy-on-write.
#
# Schema-drift guard — the reason `model:` exists. Every non-virtual scalar
# field is checked against the model's columns when the macro runs, i.e. at
# controller class load. Production eager-loads controllers, so a column
# dropped by a migration fails the deploy, not the request; the error carries
# a copy-paste migration hint. Fields not backed by a column
# (password_confirmation, terms flags) opt out with `virtual: true`; nested
# and array fields are implicitly virtual. When the schema is unreachable
# (db:create, assets:precompile) the check skips. In CI, one
# `Rails.application.eager_load!` spec exercises every contract in the app.
#
# Validation is LAZY: it runs on the first `permitted_params` call, so an
# action that never reads params never pays. `enforce: true` installs the
# check as a before_action instead (reject before the action body runs).
#
# MONITOR MODE — the rollout switch. `mode: :monitor` on a rule (or
# `Permittable.mode = :monitor` app-wide; a rule's own mode: wins) runs the
# full pipeline but REPORTS violations instead of rejecting: the same
# "invalid_parameters.permittable" event fires (payload mode: :monitor),
# the logger warns, and permitted_params returns the raw params passed
# through untouched — no casts, no defaults, no transforms — so behaviour
# is identical to the pre-contract app (a missing root: passes an empty
# hash; a rootless contract drops only the router's bookkeeping keys).
# Monitor rules validate eagerly in the before_action regardless of
# enforce:, because telemetry must not depend on the action calling
# permitted_params — legacy actions still reading `params` directly are
# exactly the ones being monitored — and monitoring can never halt the
# request. `permittable_violations` reads the recorded details ([] when
# the request was clean).
#
# THE :json FIELD — the deliberate hole. A json/jsonb column exists precisely
# so its contents need no schema, and until it was declarable a contract could
# only drop that key (strong parameters spells it `permit(metadata: {})`).
# `optional :metadata, :json` passes an arbitrary Hash through untouched —
# keys are neither filtered nor cast, and `unknown:` does not descend into it
# — while still letting the contract bound the shape it refuses to describe:
# `length:` caps the top-level key count, `max_depth:` caps container nesting
# (arrays count as a level), and `validate:`/`transform:` see the whole hash.
# Anything that is not a Hash is `invalid_type`, and the field still maps onto
# a column for the drift guard.
#
# Coercion is deliberately STRICT — ActiveModel::Type is not used, because its
# casts are lenient by design ("abc".to_i == 0, Boolean.cast("abc") == true)
# and silently corrupting untrusted input is exactly what a contract must not
# do. A value the type cannot faithfully represent is a violation, not a
# guess. nil and "" are both treated as ABSENT (the query-param convention):
# absent optional fields are OMITTED from the result (so partial updates never
# nil-out columns), absent required fields violate, and `default:` fills
# absence. `normalize:` runs BEFORE that rule rather than inside the cast, so
# there is exactly one reading of absence and a value that normalizes to empty
# ("   " under :squish) cannot satisfy a required field by becoming "". An
# authored `default:`/`example:` is stored as the contract reads it —
# normalized and cast, so `default: "18"` on an :integer is 18, and an
# array's read by the request walker itself. The one exception is a field
# declaring `transform:`: its default is stored exactly AS AUTHORED, never
# cast — `transform:` never runs on a default either (see OUTPUT RESHAPING),
# so author such a default already in the shape the action should receive.
# Either way it is deep-frozen on a copy, and each request gets its own deep
# copy, so no request can corrupt it for the next.
#
# `nullable: true` splits that rule in two for one field, which is how a PATCH
# clears a column: a key the client never sent stays absent (defaults apply,
# required violates), but a key sent EMPTY (JSON null, or "" from a form) is an
# explicit null and yields nil in the result — ahead of any `default:`, and
# without casting or checking a value that isn't there. It reads on arrays and
# nested blocks too (the array/object itself may be null, never its elements),
# and `default: nil` — legal only on a nullable field — gives the PUT reading
# where absence also means clear.
#
# Failures raise Permittable::InvalidParameters, rescued (on a real
# controller) into the shared ErrorEnvelope shape with `details:` entries of
# `{ param: "user.address.zip", code: "format" }`; a missing `root:` key
# renders 400, field violations 422. Every violation also instruments
# "invalid_parameters.permittable" so failures can be dashboarded.
#
# Violation MESSAGES stay machine-first (the code is the contract), but a
# field can attach human-readable copy with `message:` — one String for every
# code (`message: "must be a valid email"`) or a Hash per code
# (`message: { missing: "is required", format: "must be a valid email" }`).
# A resolved message rides into the detail entry as `message:` and replaces
# the "(code)" rendering in the exception's summary line; codes without a
# message keep the bare shape, so nothing changes for contracts that don't
# opt in. `violate!` in finalize accepts the same via `message:`.
#
# `sensitive: true` registers the field name with
# Permittable.filter_parameter_registry (swappable — a host gem can point it
# at its own registry), consulted at filter time by the proc
# Permittable::Railtie appends to `config.filter_parameters`. The name is
# ALSO published to that Railtie by name (see register_sensitive_parameter),
# because a proc filter can only redact String values — ActiveSupport dups
# the value and expects in-place mutation, and never calls the proc at all
# for a Hash — so a name in config.filter_parameters is what covers an
# :integer field or a sensitive nested block.
# Permittable::Railtie appends to `config.filter_parameters`. On a nested or
# array field it CASCADES to every field inside, because Rails' filtering
# asks about the leaf key it is looking at rather than the path to it; a
# sub-field opts out with `sensitive: false`, since matching is a substring
# match and a generic cascaded name would redact half the app's logs. The
# cascade is resolved onto the field data at class load — see
# ContractBuilder#cascade_sensitive.
#
# OUTPUT RESHAPING — the safe replacement for params-mutating before_actions.
# Two layers, both operating on the validated COPY (the request's `params` is
# never touched):
#   * `transform:` (scalar and array fields) — a callable applied AFTER cast
#     and validation to reshape that field's output, e.g.
#     `transform: ->(v) { v.split(",") }` turns a validated delimited String
#     into an Array. Runs only on request-supplied values: absent fields stay
#     absent, and a `default:` is handed out exactly AS AUTHORED — validated
#     against the field's own contract at class load (as any default is), but
#     neither cast nor transformed — so a request sending a field's default
#     gets the transformed value, a request omitting it the untransformed one.
#     Author a default already in the shape the action should receive:
#     `transform: ->(v) { v.to_i }, default: 25` on a :string field hands both
#     paths the Integer 25. A field with no `transform:` still gets its
#     default cast (see the module-level default:/example: paragraph above).
#   * `finalize do |p| ... end` (once per contract) — runs after every field
#     validated cleanly, receives the result hash, and must return the
#     (possibly restructured) Hash: combine parallel fields, build value
#     objects, drop scaffolding keys. It executes on a bare runner — NOT the
#     controller — so contracts stay pure data + pure functions; the only
#     extra vocabulary is `violate!(param, code)`, which records one violation
#     and halts the block immediately (the whole contract then fails as a
#     normal 422), making finalize double as the cross-field validation seam
#     ("ends_at after starts_at").
#
# Naming note: some legacy stacks (InheritedResources) define their own
# `permitted_params`; don't include both on one controller.
module Permittable
  extend ActiveSupport::Concern

  LABEL = "Permittable".freeze
  SCALAR_TYPES = %i[string integer float decimal boolean date datetime].freeze
  # Not a scalar: an opaque hash whose shape is deliberately undeclared, for
  # the json/jsonb column a contract has to be able to carry.
  JSON_TYPE = :json
  UNKNOWN_MODES = %i[ignore log error].freeze
  MODES = %i[enforce monitor].freeze
  ERROR_FORMATS = %i[envelope problem].freeze
  # Rails merges routing bookkeeping into params; a top-level (root: false)
  # unknown-keys check must not flag them.
  ROUTING_KEYS = %w[controller action format].freeze
  # Nor the keys an ordinary form POST carries — the CSRF token, the verb
  # override, the encoding probe, and the submit button's name. Without this
  # `unknown: :error` was unusable outside a JSON API: every browser form
  # failed on the framework's own keys rather than on anything the client got
  # wrong. Exempt from the CHECK only: unlike the routing keys these are NOT
  # stripped from monitor mode's raw pass-through, where handing back an
  # untouched params hash is the whole promise and a legacy action may well
  # read `_method` itself.
  FORM_KEYS = %w[authenticity_token _method utf8 commit].freeze
  # ROUTING_KEYS/FORM_KEYS name where the keys come FROM; these two name what
  # is DECIDED with them, which is what the call sites care about — and the
  # asymmetry between them is the deliberate point, so spell it once here
  # rather than leaving a bare ROUTING_KEYS to read like an oversight.
  UNCHECKED_TOP_LEVEL_KEYS = (ROUTING_KEYS + FORM_KEYS).freeze
  MONITOR_DROPPED_KEYS = ROUTING_KEYS
  # The field kinds that can hold ParamsWrapper's copy of a body — a hash. A
  # rootless contract declaring the wrapper key as one of these reads the
  # copy deliberately, so it is kept (see permittable_without_wrapper_copy).
  WRAPPER_CONTAINER_KINDS = [:nested, JSON_TYPE].freeze
  # A log line and an exception message are PROSE, written for a person. They
  # list at most this many names and count the rest, so one request cannot
  # write a megabyte of them. The machine-readable channels — a violation's
  # `details` and the instrumentation payload — stay complete; only the
  # sentence is bounded.
  PROSE_LIST_LIMIT = 10
  # ...and each name it does list is truncated. Capping the COUNT alone still
  # let ONE 1 MB key name write the 1 MB log line the cap exists to prevent.
  PROSE_ITEM_LIMIT = 120
  # ...and a name that could break the sentence out of its line is escaped.
  # The names are client-sent, and bounding their length escaped nothing: a
  # key of "x\nE, [...] ERROR -- : ..." wrote a second, forged log entry.
  # The set is, by Unicode property:
  # - every control character (Cc: C0, DEL and C1 — C1 because U+0085 is
  #   NEL, a line break to many readers, and U+009B is the 8-bit CSI that
  #   starts a terminal escape);
  # - U+2028/U+2029 (Zl, Zp), the separators a JSON-lines or JavaScript
  #   reader splits a line on;
  # - every format character (Cf): the bidi embeddings, overrides and
  #   isolates, which can visually reorder a line and so move text across
  #   the closing quote of an escaped name, and the zero-width and marker
  #   characters (U+200B, U+200E/U+200F, U+061C, U+FEFF, ...), which make
  #   two different names print identically;
  # - every space but U+0020 (Zs), so a no-break or ideographic space
  #   cannot make "x,<NBSP>y" pass for the ", " between two names.
  PROSE_UNSAFE = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Zs}&&[^ ]]/
  # A name is also quoted when it merely LOOKS like prose structure. These
  # characters print as they are — only the quoting marks them:
  # - Unicode's own Quotation_Mark property, rather than a hand-picked list:
  #   it already covers the plain and fullwidth `"`, every curly quote and
  #   guillemet (Pi/Pf), AND the CJK corner brackets U+300C/U+300D, which
  #   are real quotation marks in Japanese and Chinese text but are punctuation
  #   category Ps/Pe, not Pi/Pf, so a Pi/Pf-only check missed them;
  # - the list separator, or a fullwidth, small, ideographic or small-form-
  #   ideographic comma (the last, U+FE51, is U+3001's small-form sibling,
  #   the way U+FE50 is the plain comma's), could pass for the ", " between
  #   two names;
  # - a name that begins "and N more" (matched case-insensitively — "And"/
  #   "AND" reads identically once rendered) could pass for the overflow
  #   count. This still only catches the literal word: a homoglyph
  #   substitution such as Cyrillic "а" for Latin "a" is not detected, and
  #   no Unicode confusable-detection is attempted here — see CHANGELOG.
  PROSE_AMBIGUOUS = /\p{Quotation_Mark}|[\u{FF0C}\u{FE50}\u{3001}\u{FE51}]|, |\A(?i:and \p{Nd}+ more)/
  # \n, \r and \t, which a person recognises, get their short escape; any
  # other unsafe character is \uXXXX, which JSON, JavaScript and Ruby all
  # read the same way. The quote and backslash are escaped too, but only
  # inside an escaped (quoted) name, where they would otherwise be ambiguous.
  PROSE_ESCAPES = { "\n" => '\n', "\r" => '\r', "\t" => '\t', '"' => '\"', "\\" => '\\\\' }.freeze
  # How much of a name the prose ever reads. Every character the rendering
  # could show lies inside it even when each one is a 4-byte sequence in a
  # binary key, so a 1 MB name is converted and scanned no further than this.
  PROSE_SCAN_LIMIT = PROSE_ITEM_LIMIT * 4

  # The single proc Permittable::Railtie appends to config.filter_parameters.
  # Declared with an optional third parameter so its own arity is -3 and Rails
  # passes `original_params`; the registry's callable is then invoked by ITS
  # arity, so both the 2- and 3-argument proc-filter shapes Rails accepts work
  # as a swapped-in registry's #to_proc.
  FILTER_PARAMETER_PROC = lambda do |key, value, original = nil|
    inner = filter_parameter_registry.to_proc
    inner.arity == 2 ? inner.call(key, value) : inner.call(key, value, original)
  end.freeze

  # Named `format:` presets — the regexps every app writes by hand, defined
  # once. A preset carries something a hand-written Regexp cannot: the JSON
  # Schema `format` keyword the ecosystem understands, so an exported schema
  # says `"format": "uuid"` and not only a wall of pattern.
  #
  # :email is deliberately URI::MailTo::EMAIL_REGEXP itself, the regexp Rails
  # apps already paste into their contracts, so adopting the preset cannot
  # change which addresses an endpoint accepts. The rest avoid flags and
  # Ruby-only constructs (no \h, no /i) so they translate to ECMA-262 and
  # export as a real `pattern` rather than an x-permittable-pattern
  # extension. :url and :hostname are shape checks, not reachability
  # guarantees.
  FORMATS = {
    email: { pattern: URI::MailTo::EMAIL_REGEXP, json: "email" }.freeze,
    uuid: { pattern: /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/,
            json: "uuid" }.freeze,
    url: { pattern: %r{\Ahttps?://[^\s/?\#]+[^\s]*\z}, json: "uri" }.freeze,
    slug: { pattern: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }.freeze,
    hostname: { pattern: /\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\z/,
                json: "hostname" }.freeze
  }.freeze

  NORMALIZERS = {
    squish: ->(v) { v.squish },
    strip: ->(v) { v.strip },
    downcase: ->(v) { v.downcase },
    upcase: ->(v) { v.upcase },
    email: ->(v) { v.strip.downcase }
  }.freeze

  @registry_mutex = Mutex.new

  class << self
    # Duck-typed sink for `sensitive:` field names (#add / #include? /
    # #to_proc / #reset!). Swappable so a host gem can pool registrations into
    # its own registry (concerns_on_rails does exactly this).
    def filter_parameter_registry
      @filter_parameter_registry || @registry_mutex.synchronize do
        @filter_parameter_registry ||= FilterParameterRegistry.new
      end
    end

    # Swapping registries must not un-redact anything. Contracts that loaded
    # BEFORE the swap registered on the outgoing registry, and after the swap
    # nothing consults it any more — so its entries are carried into the new
    # one, which is the mirror image of the bug that made the proc late-bound
    # in the first place. Validated here rather than at filter time: a
    # registry with no #to_proc used to be silently never consulted, and
    # late-binding it would instead raise NoMethodError on every request.
    def filter_parameter_registry=(registry)
      unless registry.nil? || registry.respond_to?(:to_proc)
        raise ArgumentError,
              "#{LABEL}: filter_parameter_registry must respond to #to_proc (got #{registry.class})"
      end

      @registry_mutex.synchronize do
        previous = @filter_parameter_registry
        @filter_parameter_registry = registry
        next unless registry && previous.respond_to?(:names) && registry.respond_to?(:add)

        previous.names.each { |name| registry.add(name) }
      end
      registry
    end

    # The proc Permittable::Railtie appends to config.filter_parameters.
    #
    # It resolves the registry at FILTER time rather than closing over
    # whichever instance existed at boot. Rails runs railtie initializers
    # BEFORE config/initializers, so an app or host gem that swaps the
    # registry — the pooling the writer exists for — necessarily does so
    # after the Railtie has already appended its proc. A proc bound to the old
    # instance would go on consulting an empty registry and silently redact
    # nothing, while `sensitive:` fields registered themselves in the new one.
    #
    # One frozen object for the life of the process, so the Railtie's
    # idempotence check (include? before <<) holds across repeated initializer
    # runs with no memo to synchronise.
    def filter_parameter_proc
      FILTER_PARAMETER_PROC
    end

    # Every `sensitive:` registration, published to whatever is listening.
    #
    # A proc filter cannot be the whole mechanism: ActiveSupport's
    # ParameterFilter dups the value and expects in-place mutation, so a proc
    # can only redact Strings — and it is never even CALLED for a Hash value,
    # because ParameterFilter checks `value.is_a?(Hash)` first and recurses.
    # So `optional :pin, :integer, sensitive: true` and `sensitive:` on a
    # nested block both logged in the clear. What redacts any value type is a
    # NAME in config.filter_parameters, which only Rails can be told about —
    # hence a sink, installed by Permittable::Railtie, rather than Rails
    # knowledge in this file or in the registry.
    def register_sensitive_parameter(name)
      filter_parameter_registry.add(name)
      # Normalized the way the registry normalizes, so the name a sink sees is
      # the same whether it arrives here or through on_sensitive_parameter's
      # replay of #names — otherwise a sink deduplicating by value would hold
      # both :ssn and "ssn".
      name = name.to_s.downcase
      sensitive_parameter_sinks.each { |sink| sink.call(name) } unless name.empty?
      nil
    end

    # Install a sink. It is replayed over the names already registered, since
    # a contract can be declared before the Railtie's initializer runs (a
    # Permittable::Contract at require time, an eager-loaded controller) and
    # would otherwise never reach it.
    def on_sensitive_parameter(&sink)
      @registry_mutex.synchronize { sensitive_parameter_sinks << sink }
      registry = filter_parameter_registry
      registry.names.each { |name| sink.call(name) } if registry.respond_to?(:names)
      sink
    end

    # The installed sinks. Process-global, like the registry — specs that
    # install one `.clear` this afterwards.
    def sensitive_parameter_sinks
      @sensitive_parameter_sinks ||= []
    end

    # App-wide default for rules that don't declare their own mode:.
    # :enforce (the default) rejects violating requests; :monitor reports
    # them — same instrumentation event with payload mode: :monitor, plus a
    # logger.warn — and lets the request proceed with the raw params passed
    # through. This is the rollout switch for brownfield adoption: set it
    # from an initializer (Permittable.mode =
    # ENV.fetch("PERMITTABLE_MODE", "enforce").to_sym) and flip controllers
    # to their final mode one at a time, since a rule's own mode: always
    # wins over this default.
    def mode
      @mode || :enforce
    end

    def mode=(value)
      value = value.to_sym
      raise ArgumentError, "#{LABEL}: mode must be one of #{MODES.join(', ')}" unless MODES.include?(value)

      @mode = value
    end

    # The shape of a rejection: :envelope (the default — the host's
    # #render_error, or the gem's inline JSON) or :problem, which renders RFC
    # 9457 Problem Details as application/problem+json. App-wide, because the
    # error format of an API is a property of the API rather than of any one
    # contract, and set from an initializer:
    #
    #   Permittable.error_format = :problem
    #
    # See ErrorEnvelope, including why :problem opts out of #render_error.
    def error_format
      @error_format || :envelope
    end

    def error_format=(value)
      value = value.to_sym
      raise ArgumentError, "#{LABEL}: error_format must be one of #{ERROR_FORMATS.join(', ')}" unless ERROR_FORMATS.include?(value)

      @error_format = value
    end

    # Base URI for problem `type` members. Unset (the default) leaves the type
    # as RFC 9457's "about:blank"; set it to where the app documents its
    # problem types and each type gets its own URI under it.
    attr_accessor :problem_base_uri

    # Whether the schema-drift guard also checks that a field's declared type
    # matches its column's, on top of checking the column exists.
    #
    # OFF by default, deliberately. Every cross-type declaration has some
    # legitimate use — a :string contract on a date column that lets
    # ActiveRecord do the casting, a :boolean contract on a legacy integer
    # column — and breaking those apps on an upgrade would cost more than the
    # drift it catches. Turn it on and fix what it finds:
    #
    #   Permittable.check_column_types = true
    #
    # It compares type GROUPS rather than exact types, and never fires on a
    # column it has no faithful contract type for. See ColumnGuard.
    def check_column_types
      @check_column_types || false
    end

    def check_column_types=(value)
      raise ArgumentError, "#{LABEL}: check_column_types must be true or false" unless [true, false].include?(value)

      @check_column_types = value
    end

    # App-wide fallback copy for a violation code, looked up through I18n
    # under permittable.errors.<code> ("missing", "inclusion", or any Symbol
    # a validate: returned). Consulted only when the field declares no
    # matching `message:` of its own, and only when the host app has I18n —
    # without translations (or without I18n) details keep the bare
    # { param:, code: } shape, so nothing changes for apps that don't opt
    # in. Only a String translation counts; anything else (a nested Hash, a
    # missing-translation object) is ignored rather than leaked to clients.
    def default_message_for(code)
      return nil unless defined?(::I18n) && ::I18n.respond_to?(:t)

      message = ::I18n.t("permittable.errors.#{code}", default: nil)
      message.is_a?(String) ? message : nil
    end
  end

  # Raised when the request violates the matching contract. `details` is an
  # array of { param:, code: } hashes; `status` is :bad_request for a missing
  # root key, :unprocessable_entity for field violations.
  class InvalidParameters < StandardError
    attr_reader :details, :status

    def initialize(message, details: [], status: :unprocessable_entity)
      super(message)
      @details = details
      @status = status
    end
  end

  included do
    class_attribute :permittable_contracts, instance_accessor: false, default: []

    rescue_from InvalidParameters, with: :render_invalid_parameters if respond_to?(:rescue_from)
    before_action :enforce_params_contract if respond_to?(:before_action)
  end

  # Strict params-shaped coercion, shared by request-time validation and
  # macro-time `default:` checking. Every entry point returns
  # [:ok, cast_value] or [:error, code_string].
  module Coercion
    module_function

    TRUE_VALUES = [true, "true", "1", 1].freeze
    FALSE_VALUES = [false, "false", "0", 0].freeze

    # Pipeline for one scalar field: cast → in / format / length / validate.
    # `normalize:` is NOT applied here — it is its own stage, run by the
    # caller before the absence rule (a value that normalizes to "" is absent
    # like any other empty value), so normalizing again here would call a
    # host's `normalize:` proc twice per value.
    def check_scalar(field, value)
      status, value = cast(field[:type], value)
      return [status, value] unless status == :ok

      check_scalar_rules(field, value)
    end

    # `length:` first, deliberately. It is an O(1) read of a String's size,
    # while `format:` runs a regexp over the whole value and `validate:` runs
    # arbitrary app code — so checking the cheap bound last meant a value the
    # bound already excluded still paid for the expensive ones. A 5 MB string
    # against `length: 1..80` scanned all 5 MB with the field's regexp before
    # being rejected on its length, and an app regexp with poor worst-case
    # behaviour turns that from waste into a lever.
    #
    # The only observable change is which code a value violating BOTH reports:
    # `length` now, rather than `inclusion`/`format`. Reporting the structural
    # failure first is the better answer anyway — a client cannot act on
    # "wrong format" for a value that is also far too long.
    def check_scalar_rules(field, value)
      return [:error, "length"] if field[:length] && !length_ok?(field[:length], value.length)
      return [:error, "inclusion"] if field[:in] && !included_in?(field[:in], value)
      return [:error, "format"] if field[:format] && !format_match?(field[:format], value)

      check_custom(field[:validate], value)
    end

    # A Regexp RAISES rather than answers when a String's encoding cannot meet
    # it — a UTF-8 pattern with non-ASCII characters against UTF-16,
    # Shift_JIS or binary bytes (Encoding::CompatibilityError). A value the
    # pattern cannot even be applied to has not been shown to match, so it is
    # a `format` violation, the answer the client can act on. An app that
    # takes other encodings on purpose (`skip_parameter_encoding`) sees what
    # it saw before this rule, except that the crash is now a 422.
    def format_match?(pattern, value)
      pattern.match?(value)
    rescue EncodingError, ArgumentError
      false
    end

    # Free-form hash. The shape is deliberately undeclared, so the only
    # checks are the bounds the field asked for: breadth (`length:`, the
    # top-level key count, same reading as an array's element count) and
    # nesting (`max_depth:`). Shared with macro-time `default:`/`example:`
    # checking, like check_scalar.
    def check_json(field, value)
      status, code = check_json_bounds(field, value)
      return [status, code] unless status == :ok

      check_custom(field[:validate], value)
    end

    # The structural half of check_json, which the request walker runs on
    # its own so that it can copy an accepted hash before app code sees it.
    def check_json_bounds(field, value)
      return [:error, "invalid_type"] unless value.is_a?(Hash)
      return [:error, "length"] if field[:length] && !length_ok?(field[:length], value.length)
      return [:error, "depth"] if field[:max_depth] && depth_exceeds?(value, field[:max_depth])

      [:ok, value]
    end

    # Container nesting, with the field's own hash as level 1. An Array counts
    # as a level too — a deeply nested payload is a deeply nested payload
    # whichever container carries it. Bails at the first breach instead of
    # measuring the whole tree.
    def depth_exceeds?(value, limit)
      return false unless value.is_a?(Hash) || value.is_a?(Array)
      return true if limit < 1

      children = value.is_a?(Hash) ? value.each_value : value.each
      children.any? { |child| depth_exceeds?(child, limit - 1) }
    end

    # A custom validator returning a Symbol fails with that symbol as the
    # violation code; false/nil fails as "invalid"; any other truthy value
    # passes.
    def check_custom(validator, value)
      return [:ok, value] unless validator

      verdict = validator.call(value)
      return [:error, verdict.to_s] if verdict.is_a?(Symbol)
      return [:error, "invalid"] unless verdict

      [:ok, value]
    end

    def cast(type, value)
      return [:error, "invalid_type"] unless scalar_shaped?(value)
      return public_send("cast_#{type}", value) unless value.is_a?(String)
      # Bytes that are not valid in the String's OWN encoding are not text in
      # any encoding: every String operation after the cast raises on them
      # (`format:`, the normalize presets, an app's `validate:`). Rails'
      # params builder guards a controller; a standalone Contract#call on a
      # webhook payload has nothing in front of it, so `"caf\xC3"` was a 500.
      return [:error, "invalid_type"] unless value.valid_encoding?
      # A :string is handed back exactly as it arrived, in its own encoding.
      # `skip_parameter_encoding` / `param_encoding` send a controller binary
      # or Shift_JIS text ON PURPOSE, and converting it would hand the app
      # something other than what it asked Rails for.
      return cast_string(value) if type == :string

      # A UTF-8 String IS already its own inspection copy — the check just
      # above already scanned it — so utf8_text would only scan the same
      # object a second time for no new answer. Every other encoding still
      # goes through it: a US-ASCII or binary String is a NEW object once
      # force_encoding'd, and one only `encode` could produce is not yet
      # known to be valid UTF-8 at all.
      text = value.encoding == Encoding::UTF_8 ? value : utf8_text(value)
      text ? public_send("cast_#{type}", text) : [:error, "invalid_type"]
    end

    # Encodings whose bytes are READ as UTF-8 rather than converted: UTF-8
    # itself, US-ASCII (a subset of it), and binary — which names no
    # encoding at all, and is how a raw socket read or an unlabelled file
    # hands a payload over.
    UTF8_READABLE = [Encoding::UTF_8, Encoding::US_ASCII, Encoding::BINARY].freeze

    # A UTF-8 copy of a String, for INSPECTION only — the text a number, a
    # boolean or a date is parsed from — or nil when there is no UTF-8
    # reading of it. The value handed back to the app is never this copy.
    #
    # Parsing the String itself went wrong for any encoding but UTF-8:
    # `Integer()` on UTF-16 "12" raised Encoding::CompatibilityError, and
    # `BigDecimal` read the same String byte by byte and returned 1 — a wrong
    # answer where the other at least crashed.
    #
    # Binary and US-ASCII are read as UTF-8 (on a copy — the caller's String
    # keeps its encoding), anything else is converted with `encode`, and a
    # result that is not valid UTF-8, or a conversion that raises, is nil.
    def utf8_text(value)
      text = if value.encoding == Encoding::UTF_8 then value
             elsif UTF8_READABLE.include?(value.encoding) then value.dup.force_encoding(Encoding::UTF_8)
             else value.encode(Encoding::UTF_8)
             end
      text.valid_encoding? ? text : nil
    rescue EncodingError
      nil
    end

    # utf8_text for text the gem must REPORT rather than judge — a client's
    # undeclared key, written into a violation's `param`, the exception
    # message and the log line. Refusing is not an option there, so what
    # cannot be read is replaced with U+FFFD. Otherwise the undeclared key
    # "caf\xC3" was copied raw into the 422 and rendering it raised
    # JSON::GeneratorError, and a UTF-16 key raised
    # Encoding::CompatibilityError while its path was being interpolated.
    # Only undeclared keys come here (see permittable_unknown_key_violation):
    # a declared key is the contract's own UTF-8 name.
    def reportable_text(value)
      utf8_text(value) || scrubbed_text(value)
    end

    def scrubbed_text(value)
      return value.dup.force_encoding(Encoding::UTF_8).scrub if UTF8_READABLE.include?(value.encoding)

      value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    rescue EncodingError
      value.dup.force_encoding(Encoding::UTF_8).scrub
    end

    # Arrays, hashes, and nested ActionController::Parameters
    # (`?age[]=1`, `?age[x]=1`) can never satisfy a scalar type.
    def scalar_shaped?(value)
      return false if value.is_a?(Array) || value.is_a?(Hash)
      return false if defined?(ActionController::Parameters) && value.is_a?(ActionController::Parameters)

      true
    end

    # A String is returned as given. The request walker has already copied
    # it on the way in (Permittable#permittable_normalized), before
    # `normalize:` could see it — copying here as well would allocate twice
    # per value and still come too late for a mutating `normalize:` proc.
    def cast_string(value)
      case value
      when String then [:ok, value]
      # BigDecimal#to_s defaults to engineering notation ("0.15e1" for 1.5) —
      # stdlib's own rendering, only ever masked in a host that has loaded
      # Rails' active_support/core_ext/big_decimal/conversions, which patches
      # the default format to "F". A :decimal default:/example: cast through
      # here (a plain :string field, not :decimal itself) must render the same
      # way regardless of whether that patch happens to be loaded.
      when BigDecimal then [:ok, value.to_s("F")]
      when Numeric, true, false then [:ok, value.to_s]
      else [:error, "invalid_type"]
      end
    end

    def cast_integer(value)
      case value
      when Integer then [:ok, value]
      # NaN and Infinity first: `truncate` raises FloatDomainError on them (a
      # RangeError, which the ArgumentError rescue below does not catch), and
      # no integer is what either one sent. Same rule as finite_float.
      when Float then value.finite? && value == value.truncate ? [:ok, value.to_i] : [:error, "invalid_type"]
      when String then [:ok, Integer(value, 10)]
      else [:error, "invalid_type"]
      end
    rescue ArgumentError
      [:error, "invalid_type"]
    end

    def cast_float(value)
      case value
      when Numeric then finite_float(value.to_f)
      when String then finite_float(Float(value), source: value)
      else [:error, "invalid_type"]
      end
    rescue ArgumentError
      [:error, "invalid_type"]
    end

    # A Float that is not finite does not represent what was sent. "1e400"
    # overflows to Infinity and "1e-400" underflows to zero — both silently,
    # and both leaving a value no column can faithfully store.
    #
    # Underflow is only visible against the source text, since the result is
    # an ordinary 0.0: a zero result is rejected when the string it came from
    # named a nonzero SIGNIFICAND. Only the significand, because "0e10" is a
    # genuine zero whose exponent digits say nothing about the value — as are
    # "0", "0.0" and "0.0000".
    def finite_float(result, source: nil)
      return [:error, "invalid_type"] unless result.finite?
      return [:error, "invalid_type"] if result.zero? && nonzero_significand?(source)

      [:ok, result]
    end

    def nonzero_significand?(source)
      return false unless source

      source.split(/[eE]/, 2).first.match?(/[1-9]/)
    end

    def cast_decimal(value)
      case value
      when Numeric, String then finite_decimal(BigDecimal(value.to_s))
      else [:error, "invalid_type"]
      end
    rescue ArgumentError
      [:error, "invalid_type"]
    end

    # BigDecimal has no exponent limit, so a :decimal cannot overflow — but
    # BigDecimal("NaN") and BigDecimal("Infinity") SUCCEED where Float()
    # raises, so a client could send the literal string "NaN" for a price and
    # have it stored. Nothing else in the gem disagreed with itself this
    # loudly: :float rejected those strings and :decimal did not.
    def finite_decimal(result)
      result.finite? ? [:ok, result] : [:error, "invalid_type"]
    end

    def cast_boolean(value)
      return [:ok, true] if TRUE_VALUES.include?(value)
      return [:ok, false] if FALSE_VALUES.include?(value)

      [:error, "invalid_type"]
    end

    # Date.parse fills in what a string omits FROM TODAY: "09/2026" becomes
    # the 1st, "5th" becomes this month of this year. That is a guess, and a
    # non-deterministic one — the same request means different things on
    # different days — which is exactly what this coercion exists to refuse.
    # So the string must name all three parts; which format it names them in
    # is Date.parse's business, and every complete format it understands
    # ("2026-09-05", "2026/09/05", "Sep 5, 2026") still works.
    def cast_date(value)
      case value
      when Date then [:ok, value]
      when String
        found = Date._parse(value)
        return [:error, "invalid_type"] unless complete_date?(found)

        # Built from the components rather than re-running Date.parse, which
        # would parse the same string a second time — and Date.parse is the
        # expensive half. Date.new applies the same calendar validation, so
        # "2026-02-30" still fails.
        [:ok, Date.new(found[:year], found[:mon], found[:mday])]
      else [:error, "invalid_type"]
      end
    rescue ArgumentError, RangeError
      [:error, "invalid_type"]
    end

    # Date._parse is the layer under Date.parse, and reports which components
    # it actually FOUND rather than the filled-in result.
    def complete_date?(found)
      found.key?(:year) && found.key?(:mon) && found.key?(:mday)
    end

    # A zoneless String parses as UTC regardless of the host timezone
    # (deterministic); explicit offsets are honoured and normalised to UTC.
    def cast_datetime(value)
      case value
      # DateTime is listed here, ahead of Date, because it subclasses Date.
      # `getutc` rather than `utc`: `Time#utc` converts the RECEIVER, and
      # `Time#to_time` returns self, so `value.to_time.utc` silently rewrote
      # the caller's own object. A TimeWithZone's `getutc` hands back the
      # instance it caches internally, so that one is duped.
      when ActiveSupport::TimeWithZone then [:ok, value.getutc.dup]
      when Time, DateTime then [:ok, value.to_time.getutc]
      when Date then [:ok, Time.utc(value.year, value.month, value.day)]
      when String
        # Same rule as :date — the DATE part must be named in full, or it is
        # taken from today ("10:30" meant today at 10:30). An absent TIME part
        # is fine and means midnight, which is the documented reading of a
        # date given to a :datetime field.
        #
        # Unlike :date this still parses twice, deliberately: rebuilding a
        # Time from components would have to reimplement DateTime.parse's
        # handling of offsets, zone names and sub-second precision, and
        # getting that subtly wrong costs more than the parse.
        complete_date?(Date._parse(value)) ? [:ok, DateTime.parse(value).to_time.utc] : [:error, "invalid_type"]
      else [:error, "invalid_type"]
      end
    rescue ArgumentError, RangeError
      [:error, "invalid_type"]
    end

    # Presets only make sense on String input; a non-String value (JSON
    # numbers, booleans) skips normalization and goes straight to the cast.
    #
    # A String that is not valid in its own encoding is left as it came, for
    # the cast to refuse: every preset raises on invalid bytes, and an app's
    # own proc would be handed input it never agreed to see. It is not empty,
    # so the absence rule in between cannot mistake it for a missing value.
    #
    # A VALID String in another encoding is normalized in that encoding —
    # `:strip` works on binary and Shift_JIS alike — and when a BUILT-IN
    # PRESET cannot handle the encoding (`:squish` on UTF-16 raises
    # Encoding::CompatibilityError) the value is left as it is rather than
    # raising.
    #
    # That leniency is only for the gem's own presets, identified by object
    # identity against NORMALIZERS' values (resolve_normalizer! replaces
    # field[:normalize] with the exact Proc from that Hash, so a preset and
    # an app-supplied Proc are never the same object). An app's own Proc
    # raising is never swallowed, on ANY encoding: `normalize: ->(v) { raise
    # ArgumentError, "..." if ... }` is a business rule, not an encoding
    # failure, and treating its raise as "this encoding defeated the
    # normalizer" would have let exactly the input a UTF-8 request could not
    # bypass the very check it names.
    def apply_normalize(normalizer, value)
      return value unless normalizer && value.is_a?(String)
      return value unless value.valid_encoding?
      return normalizer.call(value) unless NORMALIZERS.value?(normalizer)

      begin
        normalizer.call(value)
      rescue EncodingError, ArgumentError
        value
      end
    end

    # nil and "" are both ABSENT — see the module comment. The VALUE half of
    # that rule (the walker adds the key-presence half), shared with
    # macro-time `default:`/`example:` checking so a default cannot be held
    # to a different reading of absence than the request it stands in for.
    def absent_value?(value)
      value.nil? || (value.is_a?(String) && value.empty?)
    end

    # An `in:` list as the runtime holds it: every member cast by the field's
    # own type, because included_in? compares the CAST request value against
    # it. Comparing against the members as authored meant `in: %i[draft
    # published]` on a :string field (and `in: %w[1 2 3]` on an :integer one)
    # held values no cast could ever produce, and rejected every request.
    #
    # `normalize:` is deliberately not applied — it rewrites what a client
    # sent, not what the contract author wrote. Duplicates the cast collapses
    # ("1" and 1 on an :integer) are dropped, and a Set stays a Set, so an
    # author who chose one for its O(1) include? keeps it. A nil member is
    # dropped on a nullable field, where an explicit null is accepted before
    # in: is ever consulted; anywhere else it is a member no value can equal,
    # and is an error like any other.
    #
    # `members` is what in_list returned. Returns [:ok, cast, published] —
    # `published` being what an exported enum lists, see published_in_member
    # — or [:error, offending_member, code]. Shared by ContractBuilder and the
    # RSpec matcher's `within` chain so the two cannot read a list differently.
    def cast_in_members(type, members, nullable: false)
      pairs = []
      members.each do |member|
        next if member.nil? && nullable

        status, value = cast_in_member(type, member)
        return [:error, member, value] unless status == :ok

        pairs << [value, published_in_member(type, member, value)]
      end
      pairs = pairs.uniq(&:first)
      cast_members = pairs.map(&:first)
      [:ok, members.is_a?(Set) ? cast_members.to_set : cast_members, pairs.map(&:last)]
    end

    # The members of an `in:` that is a LIST, or nil when it is not one.
    # Only Array, Set, Hash and Enumerator count, and only when the object's
    # OWN class provides the collection's ordinary include? — not a Hash,
    # Array or Set SUBCLASS overriding it (a case-insensitive allowlist, a
    # fuzzy Set, a registry matching some other way entirely). `case allowed;
    # when Hash ...` matches with ===, which for a Class is is_a?, so a
    # subclass would otherwise match its ancestor's branch and have its
    # override silently discarded — read for its raw keys/elements instead,
    # which can invert which values it actually accepts. It is left opaque
    # instead, exactly like any other object whose include? is the point
    # (see resolve_in!) and enumerating it may be expensive (a DB-backed
    # registry).
    #
    # A Hash lists its KEYS, which is what Hash#include? asks about — the
    # Rails enum idiom, `in: Post.statuses` — and, like a Set, is stored as a
    # Set, so membership stays O(1) per request.
    # ActiveSupport::HashWithIndifferentAccess is the one Hash subclass
    # accepted anyway: its include? override only canonicalises the argument
    # (String/Symbol) before the SAME key lookup, so its keys are still
    # exactly its members — and it is what a Rails enum's own reader
    # (`Post.statuses`) actually returns.
    # Enumerator::Lazy is the same story on the Enumerator side: Lazy
    # overrides chain methods like map and select, but not include?, so it
    # is still read as a list — and forced to an Array here, once, since
    # left lazy it would be cast on every request instead of at class load.
    def in_list(allowed)
      case allowed
      when Hash then allowed.keys.to_set if plain_hash?(allowed)
      when Set then allowed if allowed.instance_of?(Set)
      when Array then allowed.to_a if allowed.instance_of?(Array)
      when Enumerator then allowed.to_a if allowed.method(:include?).owner == Enumerable
      end
    end

    def plain_hash?(allowed)
      allowed.instance_of?(Hash) || allowed.instance_of?(ActiveSupport::HashWithIndifferentAccess)
    end

    # A Symbol is read as its String: it is how Ruby spells a constant
    # string, and a request never carries one, so no cast accepts it as is.
    def cast_in_member(type, member)
      member = member.to_s if member.is_a?(Symbol)
      return instant_as_date(member) if type == :date && (member.is_a?(Time) || member.is_a?(DateTime))

      cast(type, member)
    end

    # A Time or DateTime member of a :date field. ActiveSupport compares one
    # with a Date as INSTANTS, the Date standing for its midnight UTC, so
    # that instant is the only one that ever equalled a request's date. It
    # is read as that UTC date; any other instant never matched anything,
    # and is refused like any member no request could equal. (cast_date
    # would keep a DateTime whole — it IS a Date — and refuse a Time.)
    def instant_as_date(member)
      utc = member.to_time.getutc
      return [:error, "not midnight UTC, so it never equals a date"] unless utc == utc.beginning_of_day

      [:ok, utc.to_date]
    end

    # What an exported enum lists for one member: the cast value, re-encoded
    # as JSON — except a :date/:datetime member authored as a String, which
    # is published AS WRITTEN. Re-encoding a cast Time prints whole seconds,
    # so "2026-09-05T10:00:00.25Z" was published as "…10:00:00Z", a value
    # the server refuses. The authored String went through the very cast a
    # request does, so the server accepts it by construction.
    def published_in_member(type, member, value)
      member.is_a?(String) && %i[date datetime].include?(type) ? member : value
    end

    # Range#include? walks discrete ranges; cover? is the O(1) bounds check
    # and the right semantics for validation.
    def included_in?(allowed, value)
      allowed.is_a?(Range) ? allowed.cover?(value) : allowed.include?(value)
    end

    def length_ok?(spec, length)
      spec.is_a?(Range) ? spec.cover?(length) : spec == length
    end
  end

  # Builds the frozen field list from the permit_params block. Every
  # declaration is validated eagerly: a bad contract is a programmer error and
  # should fail at class load, not at request time.
  class ContractBuilder
    SCALAR_OPTS = %i[in format length default normalize validate virtual sensitive transform message desc example
                     nullable].freeze
    NESTED_OPTS = %i[virtual sensitive message desc nullable].freeze
    JSON_OPTS   = %i[length max_depth default validate virtual sensitive transform message desc example
                     nullable].freeze
    ARRAY_OPTS  = %i[of length default validate virtual sensitive required transform message desc example
                     nullable].freeze

    # One value of each scalar type as a cast produces it, for asking whether
    # an `in:` Range's endpoints can be compared with that type at all.
    RANGE_PROBES = {
      string: "", integer: 0, float: 0.0, decimal: BigDecimal("0"), boolean: true,
      date: Date.new(2000, 1, 1), datetime: Time.utc(2000)
    }.freeze

    attr_reader :finalizer

    def initialize
      @fields = []
      @finalizer = nil
    end

    def build(&)
      instance_eval(&)
      @fields.map(&:freeze).freeze
    end

    # Post-validation reshaping of the whole contract — see the module
    # comment. Once per contract, top level only.
    def finalize(&block)
      raise ArgumentError, "#{LABEL}: finalize requires a block" unless block
      raise ArgumentError, "#{LABEL}: finalize may only be declared once per contract" if @finalizer

      @finalizer = block
    end

    # `required :name` defaults the type to :string. A block instead of a
    # type declares a nested hash of sub-fields.
    def required(name, type = nil, **opts, &)
      add_field(name, type, required: true, opts: opts, &)
    end

    def optional(name, type = nil, **opts, &)
      add_field(name, type, required: false, opts: opts, &)
    end

    # Array of scalars (`of:`, default :string) or, with a block, an array
    # of nested hashes. Optional unless `required: true`; `length:`
    # constrains the element COUNT.
    def array(name, **opts, &block)
      name = field_name!(name)
      assert_opts!(name, opts, ARRAY_OPTS)
      required = opts.delete(:required) ? true : false

      field = { name: name, kind: :array, required: required, **opts }
      if block
        raise ArgumentError, "#{LABEL}: array :#{name} takes of: OR a block, not both" if opts.key?(:of)

        field[:fields] = cascade_sensitive(nested_fields!(name, &block), field[:sensitive])
        field.delete(:of)
      else
        field[:of] = scalar_type!(name, opts[:of] || :string)
      end
      validate_length!(name, field[:length]) if field.key?(:length)
      validate_callable!(name, :validate, field[:validate]) if field.key?(:validate)
      validate_callable!(name, :transform, field[:transform]) if field.key?(:transform)
      validate_array_authored_value!(field, :default) if field.key?(:default)
      validate_array_authored_value!(field, :example) if field.key?(:example)
      validate_message!(field)
      @fields << field
    end

    private

    def add_field(name, type, required:, opts:, &block)
      name = field_name!(name)
      if block
        raise ArgumentError, "#{LABEL}: :#{name} takes a type OR a nested block, not both" if type

        assert_opts!(name, opts, NESTED_OPTS)
        field = { name: name, kind: :nested, required: required,
                  fields: nested_fields!(name, &block), **opts }
        field[:fields] = cascade_sensitive(field[:fields], field[:sensitive])
        validate_message!(field)
      elsif type&.to_sym == JSON_TYPE
        assert_opts!(name, opts, JSON_OPTS)
        # `type:` is carried alongside `kind:` so the same `as(:json)` matcher
        # chain and the same error wording work as for a scalar.
        field = { name: name, kind: :json, required: required, type: JSON_TYPE, **opts }
        validate_json_opts!(field)
      else
        assert_opts!(name, opts, SCALAR_OPTS)
        field = { name: name, kind: :scalar, required: required,
                  type: scalar_type!(name, type || :string), **opts }
        validate_scalar_opts!(field)
      end
      @fields << field
    end

    def field_name!(name)
      name = name.to_sym
      raise ArgumentError, "#{LABEL}: field :#{name} is declared twice in the same contract" if @fields.any? { |f| f[:name] == name }

      name
    end

    def assert_opts!(name, opts, allowed)
      unknown = opts.keys - allowed
      return if unknown.empty?

      raise ArgumentError,
            "#{LABEL}: unknown option(s) #{unknown.map(&:inspect).join(', ')} for field :#{name} " \
            "(allowed: #{allowed.map(&:inspect).join(', ')})"
    end

    def scalar_type!(name, type)
      type = type.to_sym
      return type if SCALAR_TYPES.include?(type)

      raise ArgumentError, "#{LABEL}: field :#{name} has unknown type :#{type} " \
                           "(supported: #{SCALAR_TYPES.join(', ')})"
    end

    def nested_fields!(name, &)
      builder = ContractBuilder.new
      fields = builder.build(&)
      raise ArgumentError, "#{LABEL}: nested field :#{name} declares no sub-fields" if fields.empty?
      if builder.finalizer
        raise ArgumentError, "#{LABEL}: finalize is only available at the top level of a contract (found inside :#{name})"
      end

      fields
    end

    # `sensitive: true` on a nested or array field CASCADES to every field
    # inside it, and the cascade is resolved HERE, at class load, so that
    # `field[:sensitive]` stays the single source of truth every reader
    # consults: the filter registry, the exported schema's `writeOnly`, and
    # the RSpec matcher's `.sensitive` chain. Resolving it privately inside
    # the registry walk would have redacted a cascaded child at runtime
    # while the schema and the matcher went on calling it public.
    #
    # It has to cascade: ActiveSupport::ParameterFilter recurses into Hash
    # and Array values itself and consults proc filters only for the LEAVES,
    # handing each one the leaf's own key and never the path that led there.
    # So registering only `payment` is asked about `card_number`, which it
    # does not match, and redacts nothing inside the container.
    #
    # A sub-field opts out with an explicit `sensitive: false`, because
    # matching is a case-insensitive SUBSTRING match and cascading a generic
    # name (:id, :name) would redact every parameter app-wide that contains
    # it. Only `false` opts out; `sensitive: nil` reads as "not stated" and
    # still inherits.
    def cascade_sensitive(fields, inherited)
      updated = fields.map { |field| cascade_field_sensitive(field, inherited) }
      updated.zip(fields).all? { |new_field, old| new_field.equal?(old) } ? fields : updated.freeze
    end

    def cascade_field_sensitive(field, inherited)
      declared = field[:sensitive]
      effective = declared.nil? ? inherited : declared
      children = field[:fields] ? cascade_sensitive(field[:fields], effective) : nil
      unchanged = (effective ? declared == true : declared == false || !field.key?(:sensitive)) &&
                  (children.nil? || children.equal?(field[:fields]))
      return field if unchanged

      updated = field.merge(sensitive: effective)
      updated[:fields] = children if children
      updated.freeze
    end

    def validate_scalar_opts!(field)
      name = field[:name]
      if field[:required] && field.key?(:default)
        raise ArgumentError, "#{LABEL}: field :#{name} is required and cannot have a :default (default implies optional)"
      end

      resolve_in!(field) if field.key?(:in)
      validate_string_only_opts!(field)
      validate_length!(name, field[:length]) if field.key?(:length)
      validate_required_length!(field)
      validate_callable!(name, :validate, field[:validate]) if field.key?(:validate)
      validate_callable!(name, :transform, field[:transform]) if field.key?(:transform)
      resolve_format!(field)
      resolve_normalizer!(field)
      validate_authored_value!(field, :default)
      validate_authored_value!(field, :example)
      validate_message!(field)
    end

    # `in:` is a Range (bounds-checked with cover?), a list of values, or an
    # object of the host's own that answers include? — kept exactly as given,
    # since nothing here can know what it accepts. It used to be anything
    # answering include?, which let a String through, and String#include? is
    # a SUBSTRING test: `in: "free pro"` accepted "e", "fr" and "ee p". A
    # String is refused here, along with anything answering neither.
    #
    # A list (see Coercion.in_list — a Hash lists its keys) is stored cast by
    # the field's type (see Coercion.cast_in_members), so request-time
    # matching, the exported enum, the RSpec matcher and the column guard's
    # enum rule all read the members the runtime compares against. A member
    # no request value could ever equal is a contract mistake, and fails here
    # rather than as an `inclusion` on every request.
    def resolve_in!(field)
      name = field[:name]
      allowed = field[:in]
      if allowed.is_a?(Range)
        assert_comparable_range!(field, allowed)
      elsif (members = Coercion.in_list(allowed))
        cast_in_members!(field, members)
      elsif allowed.is_a?(String) || !allowed.respond_to?(:include?)
        raise ArgumentError, "#{LABEL}: :in for field :#{name} must be a Range, a list of values (an Array, Set, " \
                             "or a Hash read as its keys), or an object answering include? " \
                             "(got #{allowed.inspect})#{string_in_hint(allowed)}"
      end
      assert_satisfiable!(name, :in, field[:in])
    end

    def string_in_hint(allowed)
      return "" unless allowed.is_a?(String)

      " — String#include? would accept any substring; list the values instead, e.g. in: %w[#{allowed}]"
    end

    # `published` is stored only where it differs from the cast members (a
    # String-authored :date/:datetime member), so it is read as an override.
    def cast_in_members!(field, members)
      status, cast, published = Coercion.cast_in_members(field[:type], members, nullable: field[:nullable])
      unless status == :ok
        # cast is the offending member here, and published its error code.
        # nil is the one member written on purpose, meaning "null is allowed"
        # — but an absent value never reaches in:, so the fix is worth naming.
        hint = cast.nil? ? " — an absent value never reaches in:; declare nullable: true to accept an explicit null" : ""
        raise ArgumentError, "#{LABEL}: :in for field :#{field[:name]} contains #{cast.inspect}, " \
                             "which is not a valid :#{field[:type]} (#{published})#{hint}"
      end

      field[:in] = freeze_in_members(cast)
      field[:in_published] = freeze_authored(published) unless published == cast.to_a
    end

    def freeze_in_members(members)
      members.is_a?(Set) ? members.to_set { |member| freeze_authored(member) }.freeze : freeze_authored(members)
    end

    # A Range is kept exactly as written, unlike a list: casting its
    # endpoints would change what it means. `0..Float::INFINITY` on a :float
    # and `1.5..3` on an :integer are real bounds whose endpoints no cast
    # accepts, and a :decimal's `0..100` would become BigDecimal endpoints
    # that export as the STRING "0.0" where `minimum` needs a number.
    #
    # What does fail every request is an endpoint the cast value cannot be
    # compared with — `"1".."5"` on an :integer, `1..5` on a :string,
    # `.."9.99"` on a :decimal. cover? then answers false for every value, so
    # that is caught here. The probe asks exactly what cover? will — begin
    # <=> value, then value <=> end — so whatever the host's own <=> allows
    # (ActiveSupport lets a Date range bound a :datetime) is allowed here too.
    def assert_comparable_range!(field, range)
      probe = RANGE_PROBES.fetch(field[:type])
      # A NaN endpoint compares to nothing, by design, whatever it stands
      # beside — not evidence of a wrong-TYPED bound (a String range on an
      # :integer), which is what this check exists to catch. It is left
      # alone here exactly as an infinite endpoint already is (INFINITY
      # compares fine); the exporter separately omits it, since it is
      # never `finite?`.
      # Wrapped in an Array so a `false` endpoint still reads as found.
      stray = if !range.begin.nil? && !nan?(range.begin) && (range.begin <=> probe).nil? then [range.begin]
              elsif !range.end.nil? && !nan?(range.end) && (probe <=> range.end).nil? then [range.end]
              end
      return unless stray

      raise ArgumentError, "#{LABEL}: :in for field :#{field[:name]} is a Range of #{stray.first.class} " \
                           "(#{range.inspect}), which a :#{field[:type]} value cannot be compared with — " \
                           "no value could satisfy it; write the bounds as :#{field[:type]} values"
    end

    def nan?(value)
      value.respond_to?(:nan?) && value.nan?
    end

    def validate_json_opts!(field)
      name = field[:name]
      if field[:required] && field.key?(:default)
        raise ArgumentError, "#{LABEL}: field :#{name} is required and cannot have a :default (default implies optional)"
      end

      validate_length!(name, field[:length]) if field.key?(:length)
      validate_max_depth!(name, field[:max_depth]) if field.key?(:max_depth)
      validate_callable!(name, :validate, field[:validate]) if field.key?(:validate)
      validate_callable!(name, :transform, field[:transform]) if field.key?(:transform)
      validate_json_authored_value!(field, :default)
      validate_json_authored_value!(field, :example)
      validate_message!(field)
    end

    def validate_max_depth!(name, depth)
      return if depth.is_a?(Integer) && depth.positive?

      raise ArgumentError, "#{LABEL}: :max_depth for :#{name} must be a positive Integer"
    end

    # Same rule as a scalar's authored value, over check_json: a `default:` or
    # `example:` that its own bounds would reject fails at class load.
    def validate_json_authored_value!(field, opt)
      return unless field.key?(opt)
      return if authored_nil!(field, opt)
      raise ArgumentError, "#{LABEL}: :#{opt} for :#{field[:name]} must be a Hash" unless field[opt].is_a?(Hash)

      status, code = Coercion.check_json(field, field[opt])
      raise ArgumentError, "#{LABEL}: :#{opt} for field :#{field[:name]} violates its own contract (#{code})" unless status == :ok

      field[opt] = freeze_authored(field[opt])
    end

    # format / length / normalize reason about characters; on any other
    # type they would silently apply to a cast non-String and mislead.
    def validate_string_only_opts!(field)
      return if field[:type] == :string

      %i[format length normalize].each do |opt|
        next unless field.key?(opt)

        raise ArgumentError, "#{LABEL}: :#{opt} is only supported on :string fields (field :#{field[:name]} is :#{field[:type]})"
      end
    end

    def validate_length!(name, length)
      unless length.is_a?(Range) || (length.is_a?(Integer) && !length.negative?)
        raise ArgumentError, "#{LABEL}: :length for :#{name} must be a non-negative Integer or a Range " \
                             "(got #{length.inspect})"
      end

      assert_satisfiable!(name, :length, length)
    end

    # A reversed Range (5..2), an exclusive Range with equal endpoints
    # (3...3), or an empty set (in: []) excludes every value there is, so the
    # field it bounds can never validate. That used to surface as every
    # request to the action failing on that field — a contract mistake
    # reported as a client error, once per request, forever. Endless and
    # beginless Ranges are legitimate bounds, and endpoints that cannot be
    # compared are left alone rather than guessed at.
    def assert_satisfiable!(name, opt, bound)
      return unless unsatisfiable?(bound)

      raise ArgumentError, "#{LABEL}: :#{opt} for :#{name} is empty (#{bound.inspect}) — no value can satisfy it"
    end

    def unsatisfiable?(bound)
      return bound.empty? if bound.respond_to?(:empty?)
      return false unless bound.is_a?(Range) && bound.begin && bound.end

      comparison = bound.begin <=> bound.end
      return false if comparison.nil?

      bound.exclude_end? ? !comparison.negative? : comparison.positive?
    end

    # "" is ABSENT and an absent required field violates as missing, so a
    # required string can never validly be empty: a maximum length of 0
    # leaves it nothing at all to accept. The exported schema already said
    # so — minLength 1 alongside maxLength 0 — while nothing refused the
    # declaration that produced it.
    def validate_required_length!(field)
      spec = field[:length]
      return unless field[:required] && spec
      return unless Coercion.length_ok?(spec, 0) && !Coercion.length_ok?(spec, 1)

      raise ArgumentError, "#{LABEL}: :length for :#{field[:name]} is 0 on a required field — an absent or " \
                           "empty value already violates as missing, so nothing could satisfy it"
    end

    def validate_callable!(name, opt, value)
      return if value.respond_to?(:call)

      raise ArgumentError, "#{LABEL}: :#{opt} for field :#{name} must be callable"
    end

    # A Symbol (or String) `format:` names a preset; a Regexp is used as
    # given. Resolving here means request-time matching stays a plain
    # Regexp#match?, and an authored `default:`/`example:` is checked against
    # the resolved pattern like any other. The preset NAME is kept on the
    # field so exporters and the RSpec matcher can speak in presets.
    def resolve_format!(field)
      preset = field[:format]
      return if preset.nil? || preset.is_a?(Regexp)

      unless preset.is_a?(Symbol) || preset.is_a?(String)
        raise ArgumentError, "#{LABEL}: :format for field :#{field[:name]} must be a Regexp or a preset name " \
                             "(presets: #{FORMATS.keys.join(', ')})"
      end

      spec = FORMATS.fetch(preset.to_sym) do
        raise ArgumentError, "#{LABEL}: unknown :format preset :#{preset} for field :#{field[:name]} " \
                             "(presets: #{FORMATS.keys.join(', ')}, or pass a Regexp)"
      end
      field[:format_name] = preset.to_sym
      field[:format] = spec[:pattern]
    end

    def resolve_normalizer!(field)
      normalizer = field[:normalize]
      return if normalizer.nil?
      return if normalizer.respond_to?(:call) && !normalizer.is_a?(Symbol)

      field[:normalize] = NORMALIZERS.fetch(normalizer.to_sym) do
        raise ArgumentError, "#{LABEL}: unknown :normalize preset :#{normalizer} for field :#{field[:name]} " \
                             "(presets: #{NORMALIZERS.keys.join(', ')}, or pass a Proc)"
      end
    end

    # An authored value (`default:`, or a documentation `example:`) must
    # satisfy the field's own contract — catching a lie at class load beats
    # shipping it to every request (or publishing it in generated docs) —
    # which is checked here by normalizing and casting it, same as a request's
    # value. `default: "  free  "` with `normalize: :squish` is checked as
    # "free"; `default: "18"` on an :integer is checked as 18.
    #
    # What is STORED from that differs by whether the field has `transform:`.
    # With none, the cast result is stored — the form a request sending the
    # same value gets, and what used to be thrown away: `default: "18"` used
    # to be handed to every request omitting it as the String "18", and
    # `:boolean, default: "false"` gave the app a truthy String.
    # With a `transform:`, the value is stored exactly AS AUTHORED instead —
    # `transform:` never runs on a default (see AuthoredValues), so casting it
    # here would silently change its type out from under an author who, per
    # the README, writes such a default in the shape the action should
    # receive: `default: 25` beside `transform: ->(v) { v.to_i }` on a
    # :string field means the app gets the Integer 25 either way, whether the
    # request sent "25" (cast then transformed) or omitted the field
    # (authored as the already-final Integer).
    def validate_authored_value!(field, opt)
      return unless field.key?(opt)
      return if authored_nil!(field, opt)

      # Copied first, like a request's String, so a mutating `normalize:`
      # proc cannot rewrite the host's own literal.
      authored = field[opt].is_a?(String) ? field[opt].dup : field[opt]
      value = Coercion.apply_normalize(field[:normalize], authored)
      status, result = Coercion.check_scalar(field, value)
      raise ArgumentError, "#{LABEL}: :#{opt} for field :#{field[:name]} violates its own contract (#{result})" unless status == :ok

      field[opt] = freeze_authored(field[:transform] ? field[opt] : result)
    end

    # An array's authored value is validated by the REQUEST walker itself
    # (see AuthoredValues) exactly as validate_authored_value! validates a
    # scalar's: elements cast, nested hashes and arrays read at every depth, a
    # sub-field's own default: filled in, `""` on a nullable sub-field made
    # the explicit nil a request would get, keys the block does not declare
    # dropped (as `unknown: :ignore` drops them), and the array's own
    # `validate:` run over the result. A hand-rolled one-level check used to
    # cast only the top level of each element, and got every one of those
    # wrong.
    #
    # What is STORED follows the same split as a scalar's: without
    # `transform:`, the walker's read (exactly what a request sending it
    # gets); with one, the array exactly AS AUTHORED — the walker still runs,
    # so a declaration mistake (an element `validate:` refuses, a sub-field
    # default out of bounds) still fails at class load, but its cast result
    # is discarded rather than stored. `transform:` itself is deliberately
    # never run on a default either way — see AuthoredValues.
    def validate_array_authored_value!(field, opt)
      value = field[opt]
      return if authored_nil!(field, opt)
      raise ArgumentError, "#{LABEL}: :#{opt} for array :#{field[:name]} must be an Array" unless value.is_a?(Array)

      read, violations = AuthoredValues.read_array(field, value)
      unless violations.empty?
        raise ArgumentError, "#{LABEL}: :#{opt} for array :#{field[:name]} violates its own contract: " \
                             "#{AuthoredValues.summary(violations)}"
      end

      field[opt] = freeze_authored(field[:transform] ? value : read)
    end

    # A contract is frozen data, but `@fields.map(&:freeze)` freezes only the
    # field hashes — an authored `default:` or `example:` value stayed
    # mutable, and HashWithIndifferentAccess hands a non-frozen Array (and
    # any String) to the result BY REFERENCE. So one request appending to
    # `permitted_params[:tags]` corrupted the default for every later request
    # in the process. Freezing a COPY fixes that without freezing an object
    # the host app passed in and may still be using.
    def freeze_authored(value)
      deep_freeze(value.deep_dup)
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each_pair do |key, element|
          deep_freeze(key)
          deep_freeze(element)
        end
      when Array then value.each { |element| deep_freeze(element) }
      end
      value.freeze
    end

    # An authored nil is only meaningful on a nullable field, where it says
    # "absent means clear" (PUT semantics) rather than "no default". On any
    # other field it is a value nil could never satisfy, so it fails at class
    # load with the fix named.
    def authored_nil!(field, opt)
      return false unless field[opt].nil?
      return true if field[:nullable]

      raise ArgumentError,
            "#{LABEL}: :#{opt} for field :#{field[:name]} is nil but the field is not nullable — " \
            "declare nullable: true to make an explicit null part of the contract"
    end

    # `message:` customizes what the client reads for a violation on this
    # field: one String covering every code, or a Hash of code => String
    # (codes without an entry keep the default rendering). Keys are
    # normalized to Symbols here so request-time resolution is a plain
    # lookup.
    def validate_message!(field)
      spec = field[:message]
      return if spec.nil?
      return if spec.is_a?(String)

      valid_hash = spec.is_a?(Hash) && !spec.empty? &&
                   spec.all? { |code, text| (code.is_a?(Symbol) || code.is_a?(String)) && text.is_a?(String) }
      unless valid_hash
        raise ArgumentError, "#{LABEL}: :message for field :#{field[:name]} must be a String " \
                             "or a Hash of violation code => String (e.g. { missing: \"is required\" })"
      end

      field[:message] = spec.transform_keys(&:to_sym).freeze
    end
  end

  # The `self` a finalize block runs on. Deliberately bare — no controller
  # delegation — so a contract cannot grow request-state dependencies; its
  # whole vocabulary is the hash it receives plus `violate!`.
  class FinalizeRunner
    def initialize(violations)
      @violations = violations
    end

    # Records ONE violation and halts the finalize block immediately (the
    # code after a violate! call never runs, so it can assume the checked
    # invariant). The contract then fails as a normal 422. An optional
    # message: rides along into the violation detail, same as a field's
    # `message:` option.
    def violate!(param, code, message: nil)
      entry = { param: param.to_s, code: code.to_s }
      # Same resolution order as field violations: explicit message, then
      # the app's I18n copy for the code, then the bare shape.
      resolved = message ? message.to_s : Permittable.default_message_for(code)
      entry[:message] = resolved if resolved
      @violations << entry
      throw :permittable_finalize_halt
    end
  end

  class_methods do
    # Declare a params contract. No positional actions = catch-all for the
    # whole controller. Repeatable; the LAST rule matching the request's
    # action wins.
    #
    #   root:    key to unwrap first (`require(:user)` equivalent); false
    #            (default) reads top-level params. Missing root renders 400.
    #            Exactly one key: a rooted contract never sees the root's
    #            siblings (like `require(:user).permit`), so to accept
    #            several top-level envelopes stay rootless and declare one
    #            nested block per key.
    #   model:   a model class (or `true` to infer from controller_name)
    #            enabling the schema-drift check on every non-virtual scalar
    #            field.
    #   unknown: :ignore (default) / :log / :error — what to do with
    #            undeclared keys, at every nesting level.
    #   enforce: false (default) validates lazily on the first
    #            permitted_params call; true validates in a before_action.
    #   mode:    nil (default) follows Permittable.mode; :enforce rejects
    #            violating requests; :monitor reports them and passes the
    #            raw params through (see MONITOR MODE in the module
    #            comment).
    #   desc:    documentation only — carried on the rule for exporters
    #            (Permittable::OpenAPI); the runtime never reads it.
    def permit_params(*actions, root: false, model: nil, unknown: :ignore, enforce: false, mode: nil, desc: nil, &block)
      raise ArgumentError, "#{LABEL}: permit_params requires a block declaring the contract fields" unless block

      unless root.nil? || root == false || root.is_a?(Symbol) || root.is_a?(String)
        raise ArgumentError, "#{LABEL}: :root must be one key (Symbol or String) or false, got #{root.inspect} — " \
                             "to accept several top-level keys, declare a rootless contract with one nested block per key"
      end

      unknown = unknown.to_sym
      raise ArgumentError, "#{LABEL}: :unknown must be one of #{UNKNOWN_MODES.join(', ')}" unless UNKNOWN_MODES.include?(unknown)

      mode = mode&.to_sym
      if mode && !MODES.include?(mode)
        raise ArgumentError, "#{LABEL}: :mode must be one of #{MODES.join(', ')}, or nil to follow Permittable.mode"
      end

      builder = ContractBuilder.new
      fields = builder.build(&block)
      raise ArgumentError, "#{LABEL}: a contract must declare at least one field" if fields.empty?

      model_class = resolve_permit_model(model)
      guard_contract_columns!(model_class, fields) if model_class
      register_sensitive_params(fields)

      rule = { actions: actions.flatten.map(&:to_s).freeze, root: root && root.to_sym,
               model: model_class, unknown: unknown, enforce: !!enforce, mode: mode, fields: fields,
               finalize: builder.finalizer, desc: desc }.freeze
      self.permittable_contracts = permittable_contracts + [rule]
    end

    # The LAST declared rule matching `action`, or nil.
    def permit_rule_for(action)
      action = action.to_s
      permittable_contracts.reverse_each.find do |rule|
        rule[:actions].empty? || rule[:actions].include?(action)
      end
    end

    private

    def resolve_permit_model(model)
      case model
      when nil, false then nil
      when true then infer_permit_model
      else
        unless model.is_a?(Class) && model.respond_to?(:column_names)
          raise ArgumentError, "#{LABEL}: :model must be an ActiveRecord model class, true (infer from controller name), or nil"
        end

        model
      end
    end

    def infer_permit_model
      unless respond_to?(:controller_name)
        raise ArgumentError, "#{LABEL}: model: true needs controller_name to infer from — pass the class explicitly (model: SomeModel)"
      end

      name = controller_name.classify
      name.safe_constantize ||
        raise(ArgumentError, "#{LABEL}: model: true inferred #{name} from '#{controller_name}' but no such class exists — " \
                             "pass the class explicitly (model: SomeModel)")
    end

    # The drift guard. Nested/array fields are implicitly virtual — only
    # scalar fields, and the opaque `:json` field standing in for a
    # json/jsonb column, map one-to-one onto columns.
    def guard_contract_columns!(model_class, fields)
      checked = fields.select { |f| %i[scalar json].include?(f[:kind]) && !f[:virtual] }
      return if checked.empty?

      types = checked.to_h { |f| [f[:name], f[:type]] }
      allowed = checked.select { |f| f.key?(:in) }.to_h { |f| [f[:name], f[:in]] }
      begin
        ColumnGuard.ensure_columns_on!(LABEL, model_class, *checked.map { |f| f[:name] },
                                       types: types, check_types: Permittable.check_column_types,
                                       allowed: allowed)
      rescue ArgumentError => e
        # The type error carries its own guidance; only the missing-column one
        # needs the virtual: hint appended.
        raise e unless e.message.include?("does not exist in the database")

        raise ArgumentError, "#{e.message} If this parameter is not backed by a column, declare it with virtual: true."
      end
    end

    # `sensitive: true` on a nested or array field CASCADES to everything
    # inside it, because Rails' parameter filtering matches the leaf key it is
    # currently looking at — never the path that led there. Registering only
    # the container's own name therefore redacted nothing it promised: the
    # filter is handed ("payment", {...}), a Hash is not a String so nothing
    # is replaced, and it then recurses and asks about "card_number", which
    # was never registered.
    #
    # A sub-field opts out with an explicit `sensitive: false`. That escape
    # hatch exists because matching is a case-insensitive SUBSTRING match, so
    # cascading a generic name (:id, :name) would redact every parameter
    # app-wide that happens to contain it — occasionally a worse outcome than
    # the leak it prevents.
    # The cascade is already resolved on the field data (see
    # ContractBuilder#cascade_sensitive), so this only has to read it.
    def register_sensitive_params(fields)
      fields.each do |field|
        Permittable.register_sensitive_parameter(field[:name]) if field[:sensitive]
        register_sensitive_params(field[:fields]) if field[:fields]
      end
    end
  end

  # The contract's output: a HashWithIndifferentAccess of cast, validated,
  # defaulted values for the given action (default: the current action).
  # Absent optional fields are omitted. Raises InvalidParameters on
  # violation; raises ArgumentError when no contract covers the action
  # (that is a programmer error, not a client error).
  #
  # Memoized per action, and the memo remembers the OUTCOME rather than only
  # a success: a rejection is stored and re-raised. Validation is therefore
  # observable exactly once per action per request, which the
  # "invalid_parameters.permittable" event depends on — memoizing only
  # successes meant a rejected request that was read twice (an action calling
  # permittable_violations before permitted_params, say) instrumented twice
  # and double-counted itself in every dashboard.
  def permitted_params(action = nil)
    action = (action || permittable_action_name).to_s
    raise ArgumentError, "#{LABEL}: no action given and action_name is not set" if action.empty?

    @permittable_validated ||= {}
    outcome = @permittable_validated.fetch(action) do
      @permittable_validated[action] = permittable_outcome_for(action)
    end
    # `cause: nil` because a memoized rejection is raised from wherever the
    # action happens to read the params next — possibly inside a `rescue` of
    # something unrelated, whose exception Ruby would otherwise adopt as this
    # error's cause for good. The object and its original backtrace (the
    # first raise site, where the violation was found) are preserved.
    raise outcome, cause: nil if outcome.is_a?(InvalidParameters)

    outcome
  end

  # before_action entry point (public so hosts can `skip_before_action
  # :enforce_params_contract`). Two kinds of rule validate here: those that
  # opted in with `enforce: true`, and monitor-mode rules — monitoring must
  # not depend on the action calling permitted_params (legacy actions still
  # reading `params` directly are exactly the ones being monitored), and it
  # can never halt the request because monitor mode never raises.
  def enforce_params_contract
    action = permittable_action_name
    return nil unless action

    rule = self.class.permit_rule_for(action)
    permitted_params(action) if rule && (rule[:enforce] || permittable_mode(rule) == :monitor)
    nil
  end

  # The violation details recorded by validating `action` (default: the
  # current action) — [] when the request satisfied the contract. Triggers
  # the same memoized validation as permitted_params, so under monitor mode
  # this is the request-level observable ("what would have been
  # rejected?"); under enforce mode it swallows the raise and hands back
  # the details, which makes "would this request fail?" a one-liner in
  # tests.
  def permittable_violations(action = nil)
    action = (action || permittable_action_name).to_s
    @permittable_violations ||= {}
    unless @permittable_violations.key?(action)
      begin
        permitted_params(action)
      rescue InvalidParameters
        # validation recorded the details before raising
      end
    end
    @permittable_violations.fetch(action)
  end

  # rescue_from target — renders through the shared envelope (the host's
  # render_error when present, the identical inline shape otherwise).
  def render_invalid_parameters(error)
    ErrorEnvelope.render(
      self, message: error.message, status: error.status,
            code: "invalid_parameters", details: error.details
    )
  end

  private

  # ParamsWrapper copies a JSON body under the controller's wrapper key
  # (`user` for UsersController) — on by default in a Rails app — and a
  # rootless contract then saw that copy as an unknown top-level key on every
  # well-formed request. Whether the copy is Rails' own has to be read HERE,
  # before ParamsWrapper#process_action (next in the chain) runs: once it has
  # wrapped, `_wrapper_enabled?` answers false, because params now carry the
  # key. Asking afterwards could not tell Rails' copy from a client that sent
  # `user` itself, which is exactly the key the check must still flag.
  # Private, like the method it wraps — a public one would become an action.
  # A plain duck has no process_action and no ParamsWrapper, so this never
  # runs there, and the guards keep an actionpack-free host inert.
  # Assigned on every request, never only when true: a controller instance
  # dispatched twice would otherwise carry one request's exemption into the
  # next, where a `user` the client did send would pass as Rails' copy.
  def process_action(*)
    @permittable_wrapper_key = permittable_wrapper_copy_key
    super
  end

  # The wrapper key, if ParamsWrapper is about to copy the body under it;
  # nil otherwise. `_wrapper_enabled?` alone is not enough: it asks the
  # string-keyed params for the key AS CONFIGURED, so `wrap_parameters :user`
  # — the form the Rails docs use — answers "not sent" even when the client
  # sent `user` itself, and Rails wraps anyway. Asking the same params for
  # the String keeps that client's key the client's, whichever spelling the
  # host chose.
  def permittable_wrapper_copy_key
    return unless respond_to?(:_wrapper_enabled?, true) && respond_to?(:_wrapper_key, true) && _wrapper_enabled?

    key = _wrapper_key.to_s
    key unless request.parameters.key?(key)
  end

  # The value permitted_params memoizes: the validated params, or the
  # InvalidParameters that rejected them. ArgumentError is deliberately NOT
  # memoized — a contract that does not cover the action is a bug to fix, not
  # a verdict on this request, so it raises fresh on every call.
  def permittable_outcome_for(action)
    rule = self.class.permit_rule_for(action)
    raise ArgumentError, "#{LABEL}: no params contract declared covering ##{action}" unless rule

    validate_params_contract!(rule, action)
  rescue InvalidParameters => e
    e
  end

  def validate_params_contract!(rule, action)
    violations = []
    source = permittable_root_hash(rule, violations)
    result = ActiveSupport::HashWithIndifferentAccess.new
    if source
      checked = rule[:root] ? source : permittable_without_wrapper_copy(rule[:fields], source)
      result = permittable_check_hash(rule[:fields], checked, path: rule[:root] ? rule[:root].to_s : nil,
                                                              unknown: rule[:unknown], top_level: !rule[:root], violations: violations)
    end
    # finalize only sees a hash every field vouched for — never garbage.
    result = permittable_run_finalize(rule[:finalize], result, violations) if violations.empty? && rule[:finalize]
    violations.each(&:freeze)
    (@permittable_violations ||= {})[action] = violations.freeze
    return result if violations.empty?
    return permittable_monitor_pass_through(rule, source, violations) if permittable_mode(rule) == :monitor

    raise_invalid_parameters!(violations, status: source ? :unprocessable_entity : :bad_request)
  end

  # A rule's own mode: wins; otherwise the app-wide Permittable.mode.
  def permittable_mode(rule)
    rule[:mode] || Permittable.mode
  end

  # Monitor mode's violation path: emit the same instrumentation event the
  # enforce path does (payload mode: :monitor) plus a warn line, then hand
  # back exactly what the client sent — no casts, no defaults, no
  # transforms — so behaviour is identical to the pre-contract app. A
  # missing root: passes an empty hash through (the envelope you asked for
  # isn't there); a rootless contract drops only the router's bookkeeping
  # keys, mirroring their exemption from the unknown-keys check.
  def permittable_monitor_pass_through(rule, source, violations)
    permittable_instrument_violations(violations, mode: :monitor)
    if respond_to?(:logger) && logger
      logger.warn("#{LABEL}: [monitor] ##{permittable_action_name} would have been rejected: " \
                  "#{permittable_violation_summary(violations)}")
    end
    return ActiveSupport::HashWithIndifferentAccess.new unless source

    # Deliberately NOT deep-copied, unlike the enforce path's result: this is
    # the pre-contract app's own params, and `params.permit` hands its Strings
    # back by reference too — copying here would change behaviour in the one
    # mode whose promise is that nothing changes.
    passed = ActiveSupport::HashWithIndifferentAccess.new(source)
    rule[:root] ? passed : passed.except(*MONITOR_DROPPED_KEYS)
  end

  def raise_invalid_parameters!(violations, status:)
    permittable_instrument_violations(violations, mode: :enforce)
    raise InvalidParameters.new("Invalid parameters: #{permittable_violation_summary(violations)}",
                                details: violations, status: status)
  end

  def permittable_instrument_violations(violations, mode:)
    ActiveSupport::Notifications.instrument(
      "invalid_parameters.permittable",
      controller: permittable_controller_name, action: permittable_action_name, details: violations, mode: mode
    )
  end

  def permittable_violation_summary(violations)
    # The param is the client-controlled part; the message (or code) is the
    # developer's, so it is handed over separately and never escaped — a
    # YAML `|` message ending in "\n" must not quote every name it follows.
    #
    # An unknown-key violation's `param:` is already reportable_text — valid
    # UTF-8, but scrubbed to U+FFFD wherever the key wasn't. That is right
    # for `details`/instrumentation (a machine reads it and only needs it not
    # to crash `to_json`), but prose can do better: permittable_prose_utf8
    # keeps a legacy byte transcodable and an invalid one visible as \xNN
    # rather than replacing it, so prose reads the RAW key when one was
    # saved (see permittable_unknown_key_violation), and falls back to the
    # param for any other violation.
    permittable_prose_list(violations) do |v|
      name = @permittable_unknown_key_raw&.[](v) || v[:param].to_s
      [name, v[:message] ? " #{v[:message]}" : " (#{v[:code]})"]
    end
  end

  # See PROSE_LIST_LIMIT. `unknown: :error` on a request carrying 50,000
  # undeclared keys used to produce a 50,000-item sentence — a megabyte of
  # log line, or of exception message handed to every error tracker.
  # The block returns one item's name, or [name, suffix], and is called
  # only for the items actually shown — the rest are counted, never rendered.
  def permittable_prose_list(items)
    shown = items.first(PROSE_LIST_LIMIT).map { |item| permittable_prose_item(*yield(item)) }.join(", ")
    return shown if items.length <= PROSE_LIST_LIMIT

    "#{shown}, and #{items.length - PROSE_LIST_LIMIT} more"
  end

  # See PROSE_ITEM_LIMIT, PROSE_UNSAFE and PROSE_AMBIGUOUS. The item is the
  # name plus the suffix, truncated as one. Only a name that needs it is
  # quoted and escaped, judged by the part of it the truncated item would
  # SHOW — a control character past the cut is not printed, so it quotes
  # nothing. Every ordinary name therefore prints exactly as before, just
  # always as UTF-8: a Windows-1252 or binary key is converted rather than
  # written raw, and names of mixed encodings can be joined.
  def permittable_prose_item(name, suffix = "")
    text = permittable_prose_utf8(name[0, PROSE_SCAN_LIMIT])
    suffix = permittable_prose_utf8(suffix)
    more = !name[PROSE_SCAN_LIMIT].nil?
    fits = !more && text.length + suffix.length <= PROSE_ITEM_LIMIT
    shown = fits ? text : text[0, PROSE_ITEM_LIMIT - 3]
    if !shown.valid_encoding? || shown.match?(PROSE_UNSAFE) || shown.match?(PROSE_AMBIGUOUS)
      return permittable_prose_quoted(text, more, suffix)
    end

    fits ? "#{text}#{suffix}" : "#{"#{text}#{suffix}"[0, PROSE_ITEM_LIMIT - 3]}..."
  end

  # The name is truncated by whole escapes, never through one: cutting the
  # escaped text at a fixed width could print a dangling backslash, or half
  # of an escape. When the name itself is cut, the "..." goes outside the
  # closing quote, so the quotes still delimit exactly what is shown. A
  # quoted name that fits the limit on its own is never cut: the suffix is
  # cut instead, to whatever room is left — possibly none — and the "..."
  # that marks it may then run up to three characters past the limit. A
  # dropped developer suffix is better flagged than hidden, and the name is
  # the part a reader is there for. Only as many characters are escaped as
  # can be shown.
  def permittable_prose_quoted(text, more, suffix)
    budget = PROSE_ITEM_LIMIT - 2 # the two quotes
    pieces = []
    length = 0
    text.each_char do |char|
      pieces << permittable_prose_escape(char)
      length += pieces.last.length
      break if length > budget
    end
    if !more && length <= budget
      quoted = "\"#{pieces.join}\""
      return "#{quoted}#{suffix}" if quoted.length + suffix.length <= PROSE_ITEM_LIMIT

      return "#{quoted}#{suffix[0, [PROSE_ITEM_LIMIT - 3 - quoted.length, 0].max]}..."
    end

    length -= pieces.pop.length while length > budget - 3
    "\"#{pieces.join}\"..."
  end

  # A byte that is not valid UTF-8 is shown as \xNN rather than passed
  # through: it is not a character a person can read, and a lone 0x85 or
  # 0x9B is NEL or CSI to a Latin-1 terminal. A character beyond the BMP
  # (the Cf tag characters) is \u{XXXXX}, since \uXXXX holds only four digits.
  def permittable_prose_escape(char)
    return char.bytes.map { |byte| format('\x%02X', byte) }.join unless char.valid_encoding?

    PROSE_ESCAPES.fetch(char) do
      next char unless char.match?(PROSE_UNSAFE)

      char.ord > 0xFFFF ? format('\u{%X}', char.ord) : format('\u%04X', char.ord)
    end
  end

  # PROSE_UNSAFE is a UTF-8 pattern, and matching it against a binary key
  # with high bytes raises Encoding::CompatibilityError — a log line must
  # never be what fails a request. A binary key has no charset to convert
  # from, and Rack hands UTF-8 bytes over as binary, so it is read as UTF-8.
  # A key in a real encoding is transcoded character by character: what
  # maps is converted, and only a byte that does not (Windows-1252 leaves
  # 0x81, 0x8D, 0x8F, 0x90 and 0x9D undefined) is kept as an invalid byte,
  # which the escaper then shows as \xNN — rather than reading the whole
  # key as UTF-8, which turned a mappable é into \xE9 and mojibake into
  # characters the client never sent.
  def permittable_prose_utf8(item)
    return item if item.encoding == Encoding::UTF_8
    return item.dup.force_encoding(Encoding::UTF_8) if item.encoding == Encoding::BINARY || item.ascii_only?

    converter = Encoding::Converter.new(item.encoding, Encoding::UTF_8)
    source = item.dup
    out = String.new(encoding: Encoding::UTF_8)
    out << converter.primitive_errinfo[3].force_encoding(Encoding::UTF_8) until converter.primitive_convert(source, out) == :finished
    out
  rescue EncodingError # no converter, as for a dummy encoding such as UTF-7
    item.dup.force_encoding(Encoding::UTF_8)
  end

  # One violation detail entry. A field's `message:` (String, or Hash keyed
  # by code) attaches a human-readable message; entries without one keep
  # the bare { param:, code: } shape, so existing consumers see no change.
  def permittable_violation(field, param, code)
    entry = { param: param, code: code.to_s }
    message = permittable_message_for(field, code)
    entry[:message] = message if message
    entry
  end

  # Resolution order: the field's own `message:` (String, or Hash entry for
  # this code), then the app's I18n copy (permittable.errors.<code>), then
  # nothing — the bare { param:, code: } shape.
  def permittable_message_for(field, code)
    spec = field[:message]
    return spec if spec.is_a?(String)

    (spec && spec[code.to_sym]) || Permittable.default_message_for(code)
  end

  def permittable_run_finalize(finalizer, result, violations)
    runner = FinalizeRunner.new(violations)
    finalized = catch(:permittable_finalize_halt) do
      runner.instance_exec(result, &finalizer)
    end
    return result unless violations.empty?
    unless finalized.is_a?(Hash)
      raise ArgumentError,
            "#{LABEL}: finalize must return the params Hash (got #{finalized.class}) — " \
            "end the block with the hash, e.g. `p` or `p.except(:scaffolding)`"
    end

    finalized.is_a?(ActiveSupport::HashWithIndifferentAccess) ? finalized : ActiveSupport::HashWithIndifferentAccess.new(finalized)
  end

  def permittable_root_hash(rule, violations)
    raw = permittable_plain_params
    return raw unless rule[:root]

    key = rule[:root].to_s
    value = raw[key]
    return value if value.is_a?(Hash)

    # A root that is absent and a root sent with the wrong shape
    # ({"user": "bob"}) are different client mistakes, and telling a client
    # that the key it just sent is "missing" sends it looking in the wrong
    # place. Absence is the gem's own definition of it, so `{"user": ""}`
    # still reads as missing. Either way the envelope is malformed, so both
    # remain a 400.
    #
    # No field declares the root, so message resolution can only come from
    # I18n ({} has no :message).
    code = permittable_absent?(value, raw, key) ? "missing" : "invalid_type"
    violations << permittable_violation({}, key, code)
    nil
  end

  # One plain HashWithIndifferentAccess view of `params`, whatever the
  # stack: ActionController::Parameters (to_unsafe_h — this concern does
  # its own permitting, that is the point) or a plain hash in tests.
  def permittable_plain_params
    raw = params
    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    ActiveSupport::HashWithIndifferentAccess.new(raw)
  end

  def permittable_check_hash(fields, hash, path:, unknown:, top_level:, violations:)
    result = ActiveSupport::HashWithIndifferentAccess.new
    fields.each do |field|
      key = field[:name].to_s
      full = permittable_path(path, key)
      value = permittable_normalized(field, hash[key])

      if permittable_absent?(value, hash, key)
        if permittable_explicit_null?(field, hash, key)
          result[key] = nil
        elsif field.key?(:default)
          result[key] = permittable_default(field)
        elsif field[:required]
          violations << permittable_violation(field, full, "missing")
        end
        next
      end

      permittable_check_field(field, value, full, result, unknown: unknown, violations: violations)
    end
    permittable_check_unknown(fields, hash, path: path, unknown: unknown, top_level: top_level, violations: violations)
    result
  end

  def permittable_check_field(field, value, full, result, unknown:, violations:)
    key = field[:name].to_s
    case field[:kind]
    when :scalar
      # Already normalized by permittable_normalized, before the absence rule.
      permittable_check_whole(field, Coercion.check_scalar(field, value), full, result, violations: violations)
    when :json
      permittable_check_whole(field, permittable_check_json(field, value), full, result, violations: violations)
    when :nested
      if value.is_a?(Hash)
        result[key] = permittable_check_hash(field[:fields], ActiveSupport::HashWithIndifferentAccess.new(value),
                                             path: full, unknown: unknown, top_level: false, violations: violations)
      else
        violations << permittable_violation(field, full, "invalid_type")
      end
    when :array
      if value.is_a?(Array)
        result[key] = permittable_check_array(field, value, path: full, unknown: unknown, violations: violations)
      else
        violations << permittable_violation(field, full, "invalid_type")
      end
    end
  end

  # Coercion.check_json, with the copy the result needs made in the middle.
  # The opaque hash is handed over whole, and HashWithIndifferentAccess
  # rebuilt its containers but not the Strings inside them, so it is
  # deep-copied for the reason permittable_normalized copies a String — but
  # only once it is within its bounds. Copying first meant a megabyte
  # payload refused on `length:` or `max_depth:` was copied in full just to
  # be refused, undoing the early exit those bounds exist for.
  def permittable_check_json(field, value)
    status, code = Coercion.check_json_bounds(field, value)
    return [status, code] unless status == :ok

    Coercion.check_custom(field[:validate], value.deep_dup)
  end

  # The shared tail of the two kinds whose entire value is checked in one
  # call — a scalar, or an opaque hash. A clean value is transformed into the
  # result; anything else records its code.
  def permittable_check_whole(field, outcome, full, result, violations:)
    status, out = outcome
    if status == :ok
      result[field[:name].to_s] = permittable_transform(field, out)
    else
      violations << permittable_violation(field, full, out)
    end
  end

  def permittable_check_array(field, value, path:, unknown:, violations:)
    # `length:` is a BOUND, not a report. An array outside it is rejected
    # whatever its contents, so checking those contents can only add work and
    # noise: a 200k-element payload against `length: 0..10` used to cast every
    # element, collect 200k more violations, and answer with a multi-megabyte
    # 422 — for a request already refused by its first check. Stopping here
    # keeps the cost of an oversized array proportional to rejecting it.
    if field[:length] && !Coercion.length_ok?(field[:length], value.length)
      violations << permittable_violation(field, path, "length")
      return nil
    end

    before = violations.length
    out = value.each_with_index.map do |element, index|
      permittable_check_element(field, element, "#{path}[#{index}]", unknown: unknown, violations: violations)
    end
    # validate: and transform: see only a fully-valid array. A partially-nil
    # one (element violations) would hand user code garbage it never agreed
    # to see — and for validate: that was a crash, not just garbage:
    # `validate: ->(a) { a.sum < 100 }` sent `["x", 2]` raised TypeError on
    # the nil where "x" failed to cast, turning the element's 422 into a 500.
    #
    # The cost is real and accepted: the whole-array verdict is no longer
    # reported ALONGSIDE element violations. `[1, "x", 1]` against a
    # uniqueness validator reports only `ids[1]`; the client fixes it,
    # resends, and only then learns of the duplicate. Running app code over
    # nils it never agreed to handle is the worse failure.
    #
    # An undeclared key inside an element (`unknown: :error`) is not such a
    # violation: it removes nothing from the element validate: sees, so it
    # does not stop validate: from running.
    #
    # transform: is stricter, as on the scalar path: it runs only when
    # NOTHING violated, validate: included — a transform may rely on what
    # validate: checked (`Math.sqrt` after "all positive").
    elements_valid = violations.drop(before).all? { |v| permittable_unknown_key_violation?(v) }
    if field[:validate] && elements_valid
      status, code = Coercion.check_custom(field[:validate], out)
      violations << permittable_violation(field, path, code) unless status == :ok
    end
    # Transform only a fully-valid array — a partially-nil one (element
    # violations) would hand user code garbage it never agreed to see.
    violations.length == before ? permittable_transform(field, out) : out
  end

  # The one place a field's `transform:` is applied — a seam, so that
  # AuthoredValues can walk an authored default through this same walker
  # without running app code over it at class load.
  def permittable_transform(field, value)
    field[:transform] ? field[:transform].call(value) : value
  end

  def permittable_check_element(field, element, path, unknown:, violations:)
    if field[:fields]
      unless element.is_a?(Hash)
        violations << permittable_violation(field, path, "invalid_type")
        return nil
      end
      return permittable_check_hash(field[:fields], ActiveSupport::HashWithIndifferentAccess.new(element),
                                    path: path, unknown: unknown, top_level: false, violations: violations)
    end

    status, out = Coercion.cast(field[:of], permittable_own(element))
    return out if status == :ok

    violations << permittable_violation(field, path, out)
    nil
  end

  # `normalize:` runs BEFORE the absence rule, not inside the cast, so there
  # stays exactly ONE reading of absence. Otherwise a value that normalizes to
  # empty walked straight past it: `required :name, :string, normalize:
  # :squish` rejected "" as missing but accepted "   " as "" — the silent
  # corruption strict coercion exists to refuse, delivered by the gem's own
  # preset. Only scalars take normalize:, and apply_normalize is itself a
  # no-op without one, so it owns that decision for every caller.
  #
  # It is also where a request's String stops being the request's. Nothing
  # the walker hands to app code — `normalize:`, `validate:`, `transform:`,
  # the result — may alias the caller's params, or `permitted_params[:name]
  # << "x"` (or `normalize: ->(v) { v.strip! || v }`) rewrites the caller's
  # Hash or ActionController::Parameters behind the app's back. Copying at
  # the walker's input, ahead of normalize:, makes it one copy per String;
  # String#dup shares a long String's buffer copy-on-write, so the copy is
  # cheap until someone writes to it. `of:` elements get the same treatment
  # in permittable_check_element, and a :json hash in permittable_check_json.
  def permittable_normalized(field, value)
    Coercion.apply_normalize(field[:normalize], permittable_own(value))
  end

  def permittable_own(value)
    value.is_a?(String) ? value.dup : value
  end

  # An authored default belongs to the contract, which is frozen data (see
  # ContractBuilder#freeze_authored), so every request gets a deep copy of it.
  # Copying only a top-level String was not enough: HashWithIndifferentAccess
  # copies a frozen Array or Hash as it assigns it, but not what is INSIDE
  # one, so `permitted_params[:tags].first << "x"` on an `of: :string`
  # default — or any edit to a String in a :json default — raised
  # FrozenError. A deep copy leaves every value in the result the app's own
  # to mutate.
  def permittable_default(field)
    field[:default].deep_dup
  end

  # nil and "" are both ABSENT — see the module comment.
  def permittable_absent?(value, hash, key)
    !hash.key?(key) || Coercion.absent_value?(value)
  end

  # `nullable: true` splits the one absence rule in two: a key the client
  # never sent is still absent (defaults apply, required violates), but a key
  # sent EMPTY is an explicit null — the field yields nil, so a PATCH can
  # clear a column. Nothing is cast or checked: there is no value to check,
  # and `transform:` never sees a nil it did not agree to.
  def permittable_explicit_null?(field, hash, key)
    field[:nullable] && hash.key?(key)
  end

  def permittable_check_unknown(fields, hash, path:, unknown:, top_level:, violations:)
    return if unknown == :ignore

    declared = fields.map { |f| f[:name].to_s }
    extra = hash.keys.map(&:to_s) - declared
    extra -= UNCHECKED_TOP_LEVEL_KEYS + permittable_request_supplied_keys if top_level
    return if extra.empty?

    if unknown == :error
      extra.each { |key| violations << permittable_unknown_key_violation(path, key) }
    elsif respond_to?(:logger) && logger
      listed = permittable_prose_list(extra) { |key| permittable_path(path, permittable_prose_utf8(key)) }
      logger.warn("#{LABEL}: unknown parameter(s) ignored by the ##{permittable_action_name} contract: #{listed}")
    end
  end

  # The top-level keys THIS request's router put into params, beyond the
  # fixed UNCHECKED_TOP_LEVEL_KEYS: whatever it matched out of the URL
  # (`PATCH /users/1` merges `id`, which the exported OpenAPI documents as a
  # path parameter, not a body field). A controller only — a plain params
  # duck and a standalone Contract have no request, so they exempt nothing
  # extra. Subtracted from the undeclared keys, so a contract that DECLARES
  # `id` still has that field checked like any other: the value is real, the
  # URL carried it.
  def permittable_request_supplied_keys
    return [] unless respond_to?(:request) && request.respond_to?(:path_parameters)

    request.path_parameters.keys.map(&:to_s)
  end

  # A rootless contract's input without ParamsWrapper's copy of the body,
  # when Rails made one (see process_action). Removed rather than merely
  # exempted from the unknown-keys check, because the client never sent that
  # key: a contract that happens to declare a scalar or array field of the
  # wrapper's name (`optional :feedback, :string` on FeedbackController)
  # would otherwise validate Rails' copy of the whole body as that field — a
  # false 422 invalid_type for a well-formed request.
  #
  # Kept, though, when the contract declares that key as a hash container (a
  # nested block or :json): that rootless contract is reading the copy ON
  # PURPOSE, a root: spelled as a field, and it worked that way before the
  # copy was ever dropped — dropping it would turn every such request into
  # `user missing`. Top level only, where the copy lives; a rooted contract
  # reads the copy as its root, which is exactly what ParamsWrapper is for.
  # What is checked changes, not what monitor mode hands back: its raw
  # pass-through still carries the copy, as the pre-contract app's params did.
  def permittable_without_wrapper_copy(fields, source)
    key = @permittable_wrapper_key
    return source unless key
    return source if fields.any? { |f| f[:name].to_s == key && WRAPPER_CONTAINER_KINDS.include?(f[:kind]) }

    source.except(key)
  end

  def permittable_path(path, key)
    path ? "#{path}.#{key}" : key
  end

  # The one place a CLIENT's key enters a path, so the only one converted to
  # reportable UTF-8 (see Coercion.reportable_text) — every declared key a
  # request walks through is the contract's own name and is left alone.
  #
  # The entry is also remembered by identity, which is how
  # permittable_check_array tells an undeclared key from a sub-field that
  # failed. The code alone cannot: a sub-field's validate: may itself
  # return :unknown.
  def permittable_unknown_key_violation(path, key)
    entry = permittable_violation({}, permittable_path(path, Coercion.reportable_text(key)), "unknown")
    (@permittable_unknown_key_violations ||= {}.compare_by_identity)[entry] = true
    # Prose (the exception message) gets the richer transcoding instead of
    # `param:`'s scrubbed-to-U+FFFD text — see permittable_violation_summary.
    # permittable_prose_utf8, not Coercion.reportable_text, is what keeps the
    # concatenation with `path` (the contract's own UTF-8 field names) from
    # raising Encoding::CompatibilityError, the same as the :log line below.
    (@permittable_unknown_key_raw ||= {}.compare_by_identity)[entry] = permittable_path(path, permittable_prose_utf8(key))
    entry
  end

  def permittable_unknown_key_violation?(entry)
    @permittable_unknown_key_violations&.key?(entry) || false
  end

  def permittable_action_name
    respond_to?(:action_name) && action_name ? action_name.to_s : nil
  end

  def permittable_controller_name
    return controller_path if respond_to?(:controller_path)

    self.class.name
  end
end

# Class-load reading of an authored array default:/example: — the request
# walker itself, so it needs the concern's body loaded.
require "permittable/authored_values"

# Contract exporters — the other readers of the frozen contract registry.
# Loaded after the module body so OpenAPI can see the concern's own methods.
require "permittable/json_schema"
require "permittable/open_api"

# Contract WRITER — drafts permit_params blocks from a model's columns and
# existing params.permit calls (the permittable:generate rake task).
require "permittable/generator"

# Standalone contracts — the same DSL callable on any Hash, no controller.
require "permittable/contract"

# Contract COVERAGE — the registry crossed with the route set, so a
# half-covered controller is as visible as an uncovered one.
require "permittable/audit"

# Boot-time integration (filter_parameters registration, the
# permittable:openapi rake task), Rails apps only
require "permittable/railtie" if defined?(Rails::Railtie)
