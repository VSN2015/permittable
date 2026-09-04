require "active_support"
require "active_support/concern"
require "active_support/notifications"
require "active_support/hash_with_indifferent_access"
require "active_support/core_ext/hash/indifferent_access" # nested plain Hashes inside HWIA.new
require "active_support/core_ext/class/attribute"
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/string/filters"
require "bigdecimal"
require "date"
require "time"

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
# Coercion is deliberately STRICT — ActiveModel::Type is not used, because its
# casts are lenient by design ("abc".to_i == 0, Boolean.cast("abc") == true)
# and silently corrupting untrusted input is exactly what a contract must not
# do. A value the type cannot faithfully represent is a violation, not a
# guess. nil and "" are both treated as ABSENT (the query-param convention):
# absent optional fields are OMITTED from the result (so partial updates never
# nil-out columns), absent required fields violate, and `default:` fills
# absence. Clearing a column to NULL is therefore outside a contract's
# vocabulary — do that explicitly.
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
# Permittable::Railtie appends to `config.filter_parameters`.
#
# OUTPUT RESHAPING — the safe replacement for params-mutating before_actions.
# Two layers, both operating on the validated COPY (the request's `params` is
# never touched):
#   * `transform:` (scalar and array fields) — a callable applied AFTER cast
#     and validation to reshape that field's output, e.g.
#     `transform: ->(v) { v.split(",") }` turns a validated delimited String
#     into an Array. Runs only on request-supplied values: absent fields stay
#     absent and `default:` values are authored in final shape.
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
  UNKNOWN_MODES = %i[ignore log error].freeze
  MODES = %i[enforce monitor].freeze
  # Rails merges routing bookkeeping into params; a top-level (root: false)
  # unknown-keys check must not flag them.
  ROUTING_KEYS = %w[controller action format].freeze

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

    attr_writer :filter_parameter_registry

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

    # Full pipeline for one scalar field: normalize → cast → in / format /
    # length / validate.
    def check_scalar(field, value)
      value = apply_normalize(field[:normalize], value)
      status, value = cast(field[:type], value)
      return [status, value] unless status == :ok

      check_scalar_rules(field, value)
    end

    def check_scalar_rules(field, value)
      return [:error, "inclusion"] if field[:in] && !included_in?(field[:in], value)
      return [:error, "format"] if field[:format] && !field[:format].match?(value)
      return [:error, "length"] if field[:length] && !length_ok?(field[:length], value.length)

      check_custom(field[:validate], value)
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

      public_send("cast_#{type}", value)
    end

    # Arrays, hashes, and nested ActionController::Parameters
    # (`?age[]=1`, `?age[x]=1`) can never satisfy a scalar type.
    def scalar_shaped?(value)
      return false if value.is_a?(Array) || value.is_a?(Hash)
      return false if defined?(ActionController::Parameters) && value.is_a?(ActionController::Parameters)

      true
    end

    def cast_string(value)
      case value
      when String then [:ok, value]
      when Numeric, true, false then [:ok, value.to_s]
      else [:error, "invalid_type"]
      end
    end

    def cast_integer(value)
      case value
      when Integer then [:ok, value]
      when Float then value == value.truncate ? [:ok, value.to_i] : [:error, "invalid_type"]
      when String then [:ok, Integer(value, 10)]
      else [:error, "invalid_type"]
      end
    rescue ArgumentError
      [:error, "invalid_type"]
    end

    def cast_float(value)
      case value
      when Numeric then [:ok, value.to_f]
      when String then [:ok, Float(value)]
      else [:error, "invalid_type"]
      end
    rescue ArgumentError
      [:error, "invalid_type"]
    end

    def cast_decimal(value)
      case value
      when Numeric, String then [:ok, BigDecimal(value.to_s)]
      else [:error, "invalid_type"]
      end
    rescue ArgumentError
      [:error, "invalid_type"]
    end

    def cast_boolean(value)
      return [:ok, true] if TRUE_VALUES.include?(value)
      return [:ok, false] if FALSE_VALUES.include?(value)

      [:error, "invalid_type"]
    end

    def cast_date(value)
      case value
      when Date then [:ok, value]
      when String then [:ok, Date.parse(value)]
      else [:error, "invalid_type"]
      end
    rescue ArgumentError, RangeError
      [:error, "invalid_type"]
    end

    # A zoneless String parses as UTC regardless of the host timezone
    # (deterministic); explicit offsets are honoured and normalised to UTC.
    def cast_datetime(value)
      case value
      # DateTime is listed here, ahead of Date, because it subclasses Date.
      when ActiveSupport::TimeWithZone, Time, DateTime then [:ok, value.to_time.utc]
      when Date then [:ok, Time.utc(value.year, value.month, value.day)]
      when String then [:ok, DateTime.parse(value).to_time.utc]
      else [:error, "invalid_type"]
      end
    rescue ArgumentError, RangeError
      [:error, "invalid_type"]
    end

    # Presets only make sense on String input; a non-String value (JSON
    # numbers, booleans) skips normalization and goes straight to the cast.
    def apply_normalize(normalizer, value)
      return value unless normalizer && value.is_a?(String)

      normalizer.call(value)
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
    SCALAR_OPTS = %i[in format length default normalize validate virtual sensitive transform message desc example].freeze
    NESTED_OPTS = %i[virtual sensitive message desc].freeze
    ARRAY_OPTS  = %i[of length default validate virtual sensitive required transform message desc example].freeze

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

        field[:fields] = nested_fields!(name, &block)
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
        validate_message!(field)
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

    def validate_scalar_opts!(field)
      name = field[:name]
      if field[:required] && field.key?(:default)
        raise ArgumentError, "#{LABEL}: field :#{name} is required and cannot have a :default (default implies optional)"
      end
      if field.key?(:in) && !field[:in].respond_to?(:include?)
        raise ArgumentError, "#{LABEL}: :in for field :#{name} must respond to include? (Range or Array)"
      end

      validate_string_only_opts!(field)
      validate_length!(name, field[:length]) if field.key?(:length)
      validate_callable!(name, :validate, field[:validate]) if field.key?(:validate)
      validate_callable!(name, :transform, field[:transform]) if field.key?(:transform)
      resolve_normalizer!(field)
      validate_authored_value!(field, :default)
      validate_authored_value!(field, :example)
      validate_message!(field)
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
      return if length.is_a?(Range) || length.is_a?(Integer)

      raise ArgumentError, "#{LABEL}: :length for :#{name} must be a Range or Integer"
    end

    def validate_callable!(name, opt, value)
      return if value.respond_to?(:call)

      raise ArgumentError, "#{LABEL}: :#{opt} for field :#{name} must be callable"
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
    # shipping it to every request (or publishing it in generated docs).
    def validate_authored_value!(field, opt)
      return unless field.key?(opt)

      status, code = Coercion.check_scalar(field, field[opt])
      return if status == :ok

      raise ArgumentError, "#{LABEL}: :#{opt} for field :#{field[:name]} violates its own contract (#{code})"
    end

    def validate_array_authored_value!(field, opt)
      value = field[opt]
      raise ArgumentError, "#{LABEL}: :#{opt} for array :#{field[:name]} must be an Array" unless value.is_a?(Array)
      return unless field[:of]

      value.each do |element|
        status, code = Coercion.cast(field[:of], element)
        next if status == :ok

        raise ArgumentError, "#{LABEL}: :#{opt} for array :#{field[:name]} contains an element violating of: :#{field[:of]} (#{code})"
      end
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
    # scalar fields map one-to-one onto columns.
    def guard_contract_columns!(model_class, fields)
      checked = fields.select { |f| f[:kind] == :scalar && !f[:virtual] }
      return if checked.empty?

      types = checked.to_h { |f| [f[:name], f[:type]] }
      begin
        ColumnGuard.ensure_columns_on!(LABEL, model_class, *checked.map { |f| f[:name] }, types: types)
      rescue ArgumentError => e
        raise ArgumentError, "#{e.message} If this parameter is not backed by a column, declare it with virtual: true."
      end
    end

    def register_sensitive_params(fields)
      fields.each do |field|
        Permittable.filter_parameter_registry.add(field[:name]) if field[:sensitive]
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
    if @permittable_validated.key?(action)
      outcome = @permittable_validated[action]
      raise outcome if outcome.is_a?(InvalidParameters)

      return outcome
    end

    rule = self.class.permit_rule_for(action)
    raise ArgumentError, "#{LABEL}: no params contract declared covering ##{action}" unless rule

    @permittable_validated[action] = validate_params_contract!(rule, action)
  rescue InvalidParameters => e
    # ArgumentError is deliberately NOT memoized: a contract that does not
    # cover the action is a bug to fix, not a verdict on this request.
    @permittable_validated[action] = e
    raise
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

  def validate_params_contract!(rule, action)
    violations = []
    source = permittable_root_hash(rule, violations)
    result = ActiveSupport::HashWithIndifferentAccess.new
    if source
      result = permittable_check_hash(rule[:fields], source, path: rule[:root] ? rule[:root].to_s : nil,
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

    passed = ActiveSupport::HashWithIndifferentAccess.new(source)
    rule[:root] ? passed : passed.except(*ROUTING_KEYS)
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
    violations.map { |v| v[:message] ? "#{v[:param]} #{v[:message]}" : "#{v[:param]} (#{v[:code]})" }.join(", ")
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

    value = raw[rule[:root].to_s]
    return value if value.is_a?(Hash)

    # No field declares the root, so message resolution can only come from
    # I18n ({} has no :message).
    violations << permittable_violation({}, rule[:root].to_s, "missing")
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
      value = hash[key]

      if permittable_absent?(value, hash, key)
        if field.key?(:default)
          result[key] = field[:default]
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
      status, out = Coercion.check_scalar(field, value)
      if status == :ok
        out = field[:transform].call(out) if field[:transform]
        result[key] = out
      else
        violations << permittable_violation(field, full, out)
      end
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

  def permittable_check_array(field, value, path:, unknown:, violations:)
    before = violations.length
    violations << permittable_violation(field, path, "length") if field[:length] && !Coercion.length_ok?(field[:length], value.length)
    out = value.each_with_index.map do |element, index|
      permittable_check_element(field, element, "#{path}[#{index}]", unknown: unknown, violations: violations)
    end
    if field[:validate]
      status, code = Coercion.check_custom(field[:validate], out)
      violations << permittable_violation(field, path, code) unless status == :ok
    end
    # Transform only a fully-valid array — a partially-nil one (element
    # violations) would hand user code garbage it never agreed to see.
    out = field[:transform].call(out) if field[:transform] && violations.length == before
    out
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

    status, out = Coercion.cast(field[:of], element)
    return out if status == :ok

    violations << permittable_violation(field, path, out)
    nil
  end

  # nil and "" are both ABSENT — see the module comment.
  def permittable_absent?(value, hash, key)
    !hash.key?(key) || value.nil? || (value.is_a?(String) && value.empty?)
  end

  def permittable_check_unknown(fields, hash, path:, unknown:, top_level:, violations:)
    return if unknown == :ignore

    declared = fields.map { |f| f[:name].to_s }
    extra = hash.keys.map(&:to_s) - declared
    extra -= ROUTING_KEYS if top_level
    return if extra.empty?

    if unknown == :error
      extra.each { |key| violations << permittable_violation({}, permittable_path(path, key), "unknown") }
    elsif respond_to?(:logger) && logger
      logger.warn("#{LABEL}: unknown parameter(s) ignored by the ##{permittable_action_name} contract: " \
                  "#{extra.map { |key| permittable_path(path, key) }.join(', ')}")
    end
  end

  def permittable_path(path, key)
    path ? "#{path}.#{key}" : key
  end

  def permittable_action_name
    respond_to?(:action_name) && action_name ? action_name.to_s : nil
  end

  def permittable_controller_name
    return controller_path if respond_to?(:controller_path)

    self.class.name
  end
end

# Contract exporters — the other readers of the frozen contract registry.
# Loaded after the module body so OpenAPI can see the concern's own methods.
require "permittable/json_schema"
require "permittable/open_api"

# Contract WRITER — drafts permit_params blocks from a model's columns and
# existing params.permit calls (the permittable:generate rake task).
require "permittable/generator"

# Standalone contracts — the same DSL callable on any Hash, no controller.
require "permittable/contract"

# Boot-time integration (filter_parameters registration, the
# permittable:openapi rake task), Rails apps only
require "permittable/railtie" if defined?(Rails::Railtie)
