require "permittable"

module Permittable
  # RSpec matchers for asserting on declared contracts — the testing
  # counterpart of "a contract is data": the matcher reads the same frozen
  # rule the validator enforces, so a contract can be specified without
  # dispatching a single request.
  #
  #   # spec_helper.rb (matchers auto-include when RSpec is defined)
  #   require "permittable/rspec"
  #
  #   expect(UsersController).to permit_param(:age)
  #     .for_action(:create).as(:integer).within(18..120)
  #   expect(UsersController).to permit_param("address.zip").as(:string).optional
  #   expect(UsersController).not_to permit_param(:admin).for_action(:create)
  #
  # The negated form asserts that the contract does not declare the param,
  # and takes no qualifiers: `not_to permit_param(:admin).required` would
  # pass both when :admin is undeclared and when it is declared optional,
  # which is a false positive in exactly the assertion most likely to guard
  # a security property. It raises instead, and names the positive form to
  # write. It reads the contract, not the runtime mode: under a rule in
  # monitor mode, permitted_params hands back undeclared keys regardless.
  #
  # `for_action` picks the rule exactly like a request would
  # (`permit_rule_for`); it may be omitted only when the controller declares
  # a single contract, so an ambiguous expectation fails loudly instead of
  # silently checking the wrong rule.
  module Matchers
    def permit_param(path)
      PermitParamMatcher.new(path)
    end

    # What the contract DOES with a payload, as opposed to what it declares.
    #
    #   expect(UsersController).to accept_params(user: { name: "Jo" })
    #     .for_action(:create).returning("name" => "Jo", "plan" => "free")
    #
    #   expect(UsersController).to reject_params(user: {})
    #     .for_action(:create).with_violation("user.name", :missing)
    #
    # No request is dispatched: the rule is run against the payload directly,
    # so these work on a controller class, a controller instance, or a
    # standalone Permittable::Contract.
    def accept_params(params)
      ParamsBehaviourMatcher.new(params, expect_accepted: true)
    end

    def reject_params(params)
      ParamsBehaviourMatcher.new(params, expect_accepted: false)
    end

    class PermitParamMatcher
      OPTION_LABELS = { in: "in:", format: "format:", length: "length:", default: "default:" }.freeze
      # One path segment: a name plus any [n] indexes (the runtime's form).
      SEGMENT = /\A([^\[\]]+)((?:\[\d+\])*)\z/

      def initialize(path)
        @path = path.to_s
        @segments = path_segments!(@path)
        @action = nil
        @expected = {}
      end

      # -- chains -----------------------------------------------------------

      def for_action(action)
        @action = action.to_s
        self
      end

      def as(type)
        @expected[:type] = type.to_sym
        self
      end

      def as_array(of: nil)
        @expected[:array] = true
        @expected[:of] = of.to_sym if of
        self
      end

      def required
        @expected[:required] = true
        self
      end

      def optional
        @expected[:required] = false
        self
      end

      def within(allowed)
        @expected[:in] = allowed
        self
      end

      def matching(regexp)
        @expected[:format] = regexp
        self
      end

      def with_length(spec)
        @expected[:length] = spec
        self
      end

      def with_default(value)
        @expected[:default] = value
        self
      end

      def virtual
        @expected[:virtual] = true
        self
      end

      def sensitive
        @expected[:sensitive] = true
        self
      end

      def nullable
        @expected[:nullable] = true
        self
      end

      # -- RSpec protocol ---------------------------------------------------

      def matches?(subject)
        @subject = resolve_subject(subject)
        case locate
        when :declared then @mismatches = collect_mismatches(@field)
        when :opaque then @mismatches = @expected.empty? ? [] : [opaque_qualifier_mismatch]
        else return false
        end
        @mismatches.empty?
      end

      # Negation is only unambiguous without qualifiers ("not declared"),
      # and only meaningful against a rule that exists: a mistyped
      # `for_action(:craete)` with no catch-all rule resolves to no rule,
      # which declares nothing, so a lenient not_to would pass for any param
      # whatsoever. (With a catch-all it resolves there, as a request
      # would, and is checked against that rule.) The subject is
      # resolved first so a wrong subject is the error reported.
      def does_not_match?(subject) # rubocop:disable Naming/PredicatePrefix -- the RSpec protocol name
        @subject = resolve_subject(subject)
        raise ArgumentError, negated_qualifier_message unless @expected.empty?

        %i[undeclared too_deep].include?(locate)
      end

      def failure_message
        subject = "expected #{subject_name} to permit #{path_label}#{action_label}, but"
        case @status
        when :no_rule then "#{subject} it #{@problem}"
        when :root_prefixed then "#{subject} #{root_prefix_hint}"
        when :too_deep
          "#{subject} it is deeper than the opaque :json field #{label_for(@opaque[:path])} allows " \
          "(max_depth: #{@opaque[:field][:max_depth]})"
        when :undeclared
          "#{subject} it is not declared (declared: #{(@missing_among || []).map { |f| f[:name] }.join(', ')})"
        else "#{subject}:\n  #{@mismatches.join("\n  ")}"
        end
      end

      def failure_message_when_negated
        subject = "expected #{subject_name} not to permit #{path_label}#{action_label}, but"
        case @status
        when :no_rule then "#{subject} it #{@problem}, so there is no rule to check the param against"
        when :opaque
          "#{subject} it is inside the opaque :json field #{label_for(@opaque[:path])}, which lets any nested key through"
        when :root_prefixed then "#{subject} #{root_prefix_hint} — which the contract lets through"
        else "#{subject} the contract declares it"
        end
      end

      def description
        label = "permit #{path_label}"
        label += " (for ##{@action})" if @action
        label += " #{descriptors.join(', ')}" unless descriptors.empty?
        label
      end

      def supports_block_expectations?
        false
      end

      private

      # A controller CLASS carries the contract registry; an instance (a
      # controller spec's `controller` / `subject`) resolves through its
      # class. Anything answering permit_rule_for itself is used as-is.
      def resolve_subject(subject)
        return subject if subject.respond_to?(:permit_rule_for)
        return subject.class if subject.class.respond_to?(:permit_rule_for)

        raise ArgumentError, "#{LABEL}: the subject of permit_param must include Permittable (got #{subject.inspect})"
      end

      # The one lookup both directions share. Sets @status to :no_rule,
      # :declared, :opaque (the path runs into a :json field, which accepts
      # any nested key without declaring it), :too_deep (it runs into one
      # deeper than its max_depth: allows), :root_prefixed (the path starts
      # with the rule's root: and resolves without it), or :undeclared.
      # Every per-run ivar is reset first: a matcher object can be reused
      # on another subject, and must not answer from the previous run.
      def locate
        @rule = @field = @opaque = @problem = @missing_among = nil
        @mismatches = []
        @rule = resolve_rule(@subject)
        return @status = :no_rule unless @rule

        @field = resolve_field(@rule[:fields], @segments)
        @status = if @field then :declared
                  elsif @opaque then opaque_within_depth? ? :opaque : :too_deep
                  elsif root_prefixed? then :root_prefixed
                  else :undeclared
                  end
      end

      def resolve_rule(subject)
        return resolve_rule_for_action(subject) if @action

        contracts = subject.permittable_contracts
        case contracts.length
        when 0 then record_problem("declares no contracts")
        when 1 then contracts.first
        else
          raise ArgumentError, "#{LABEL}: #{subject_name} declares #{contracts.length} contracts — " \
                               "disambiguate with permit_param(...).for_action(:action)"
        end
      end

      def resolve_rule_for_action(subject)
        subject.permit_rule_for(@action) || record_problem("has no contract covering ##{@action}")
      end

      def record_problem(problem)
        @problem = problem
        nil
      end

      # Walks a dotted path through nested blocks and array-of-hash blocks
      # alike, since both carry their sub-fields under :fields. A :json
      # field is opaque: it has no :fields, yet lets any nested key through,
      # so a path running past one is recorded rather than called missing,
      # along with how many container levels the rest of the path needs.
      def resolve_field(fields, segments, depth = 0)
        name = segments[depth][:name].to_sym
        field = fields.find { |f| f[:name] == name }
        if field.nil?
          @missing_among = fields
          return nil
        end
        return field if depth == segments.length - 1

        if field[:kind] == :json
          @opaque = { path: segments.take(depth + 1).map { |seg| seg[:name] }.join("."), field: field,
                      steps: steps_below(segments, depth) }
          return nil
        end

        resolve_field(field[:fields] || [], segments, depth + 1)
      end

      # Each key or [n] step past the :json field descends into one more
      # container — the same count the runtime's max_depth: check makes,
      # where the field's own Hash is the first level and arrays count too.
      def steps_below(segments, depth)
        (segments.length - depth - 1) + segments.drop(depth).sum { |seg| seg[:indexes] }
      end

      def opaque_within_depth?
        limit = @opaque[:field][:max_depth]
        limit.nil? || @opaque[:steps] <= limit
      end

      # Paths are relative to root:, so "user.email" under `root: :user`
      # names params[:user][:user][:email]. When dropping the prefix would
      # resolve (to a declared field, or into an opaque :json one within its
      # max_depth:), that is almost certainly what was meant — and silently
      # passing a negated expectation on it would be a false pass.
      def root_prefixed?
        root = @rule[:root]
        return false unless root && @segments.length > 1 && @segments.first[:name] == root.to_s

        missing_among = @missing_among
        found = resolve_field(@rule[:fields], @segments.drop(1)) || (@opaque && opaque_within_depth?)
        @missing_among = missing_among
        @opaque = nil
        found ? true : false
      end

      def root_prefix_hint
        relative = @segments.drop(1).map { |seg| seg[:raw] }.join(".")
        "paths are relative to root: :#{@rule[:root]}, so write permit_param(#{label_for(relative)})"
      end

      def opaque_qualifier_mismatch
        "it is inside the opaque :json field #{label_for(@opaque[:path])}, which declares nothing about its keys — " \
          "assert qualifiers on #{label_for(@opaque[:path])} itself"
      end

      # Accepts the runtime's own path form too — violation details say
      # "line_items[0].sku" — so a path copied from one resolves: the [n]
      # indexes are dropped for the walk and kept only as depth.
      def path_segments!(path)
        raws = path.split(".", -1)
        matches = raws.map { |raw| SEGMENT.match(raw) }
        if raws.empty? || matches.any?(&:nil?)
          raise ArgumentError, "#{LABEL}: permit_param needs a param name or a dotted path like " \
                               "\"address.zip\" or \"line_items[0].sku\" (got #{path.inspect})"
        end

        raws.zip(matches).map { |raw, m| { name: m[1], indexes: m[2].count("["), raw: raw } }
      end

      def collect_mismatches(field)
        @expected.filter_map { |key, value| check_mismatch(field, key, value) }
      end

      def check_mismatch(field, key, value)
        case key
        when :type then type_mismatch(field, value)
        when :array then "expected an array field, but it is declared with `#{field[:kind]}`" unless field[:kind] == :array
        when :of then of_mismatch(field, value)
        when :required then required_mismatch(field, value)
        when :format then format_mismatch(field, value)
        # Compared cast, but reported as written.
        when :default then default_mismatch(field, value)
        when :in then option_mismatch(field, :in, value) unless field.key?(:in) && same_in?(field[:in], cast_in(field, value))
        when :virtual, :sensitive, :nullable then "expected the field to be #{key}, but it is not" unless field[key]
        else option_mismatch(field, key, value)
        end
      end

      # A non-array field is already reported by the :array check that
      # as_array always chains alongside :of, so this stays silent for it;
      # an array of hashes has sub-fields rather than an element type.
      def of_mismatch(field, type)
        return if field[:kind] != :array || field[:of] == type
        return "expected an array of :#{type}, but :#{field[:name]} is an array of hashes" if field[:fields]

        "expected an array of :#{type}, but it is of: :#{field[:of]}"
      end

      def type_mismatch(field, type)
        if field[:kind] == :array && field[:fields]
          "expected type :#{type}, but :#{field[:name]} is an array of hashes — assert it with as_array"
        elsif field[:kind] == :array
          "expected type :#{type}, but :#{field[:name]} is an array — assert it with as_array(of: ...)"
        elsif field[:kind] == :nested
          "expected type :#{type}, but :#{field[:name]} is a nested hash"
        elsif field[:type] != type
          "expected type #{type.inspect}, but the contract declares #{field[:type].inspect}"
        end
      end

      def required_mismatch(field, required)
        actual = field[:required] ? "required" : "optional"
        expected = required ? "required" : "optional"
        "expected the field to be #{expected}, but it is #{actual}" unless actual == expected
      end

      # `matching(:email)` asserts the preset by name, `matching(/re/)` the
      # Regexp itself.
      def format_mismatch(field, expected)
        return option_mismatch(field, :format, expected) unless expected.is_a?(Symbol)
        return if field[:format_name] == expected

        "expected format: :#{expected}, but the contract #{declared_format(field)}"
      end

      def default_mismatch(field, expected)
        option_mismatch(field, :default, expected) unless field.key?(:default) && field[:default] == cast_default(field, expected)
      end

      # A contract stores its `default:` as the field reads it — cast,
      # normalized, and for an array read by the request walker — so
      # `with_default("18")` on an :integer, the declaration repeated as
      # written, is read the same way before comparing, by the same code. A
      # value that does not read cleanly is compared as given, and the
      # failure shows both sides.
      #
      # A field declaring `transform:` stores its default AS AUTHORED instead
      # (see validate_authored_value!/validate_array_authored_value!), so
      # `expected` is compared bare, not cast — the matcher would otherwise
      # compare a cast value against an uncast stored one and never match.
      def cast_default(field, expected)
        return expected if field[:transform]

        case field[:kind]
        when :scalar
          # Copied first, like a request's String, so a mutating `normalize:`
          # proc cannot rewrite the spec's own literal (the same reason
          # validate_authored_value! copies before normalizing).
          own = expected.is_a?(String) ? expected.dup : expected
          status, value = Coercion.cast(field[:type], Coercion.apply_normalize(field[:normalize], own))
          status == :ok ? value : expected
        when :array
          return expected unless expected.is_a?(Array)

          value, violations = AuthoredValues.read_array(field, expected)
          violations.empty? ? value : expected
        else expected
        end
      end

      # A contract stores an `in:` list cast by the field's type, so
      # `within(%i[draft published])` — the declaration repeated as written —
      # is read the same way before comparing, by the same two functions the
      # contract uses: what counts as a list (a Hash as its keys), then the
      # cast. Anything that is not a list, or does not cast, is compared as
      # given — a Range and a host's own allowlist are stored as given too.
      def cast_in(field, expected)
        members = field[:kind] == :scalar && Coercion.in_list(expected)
        return expected unless members

        status, cast = Coercion.cast_in_members(field[:type], members, nullable: field[:nullable])
        status == :ok ? cast : expected
      end

      # A list's order and container say nothing about what it allows:
      # `in: Post.statuses` is stored as a Set, and `within(%w[draft
      # published])` names exactly its values.
      def same_in?(declared, expected)
        lists = [declared, expected].all? { |list| list.is_a?(Array) || list.is_a?(Set) }
        lists ? declared.to_set == expected.to_set : declared == expected
      end

      def declared_format(field)
        return "declares format: :#{field[:format_name]}" if field[:format_name]
        return "declares format: #{field[:format].inspect}" if field[:format]

        "does not declare format:"
      end

      def option_mismatch(field, key, value)
        return if field.key?(key) && field[key] == value

        label = OPTION_LABELS.fetch(key)
        declared = field.key?(key) ? "declares #{label} #{field[key].inspect}" : "does not declare #{label}"
        "expected #{label} #{value.inspect}, but the contract #{declared}"
      end

      def negated_qualifier_message
        "#{LABEL}: `not_to #{call_label}` cannot take qualifiers (here: #{descriptors.join(', ')}) — " \
          "negating one is ambiguous, since it would pass both when #{path_label} is not declared and " \
          "when it is declared differently. Assert what the contract does declare with " \
          "the positive form, e.g. #{positive_example}, or drop the qualifiers to assert that " \
          "#{path_label} is not declared at all."
      end

      # required/optional is the one qualifier with an obvious opposite;
      # for any other the declared value is not known until the rule is
      # read, so the example stays generic rather than guessing it.
      def positive_example
        case @expected
        when { required: true } then "`to #{call_label}.optional`"
        when { required: false } then "`to #{call_label}.required`"
        else "`to #{call_label}` chained with the qualifiers it should have"
        end
      end

      def call_label
        "permit_param(#{path_label})#{".for_action(:#{@action})" if @action}"
      end

      def descriptors
        @expected.filter_map { |key, value| describe_check(key, value) }
      end

      def describe_check(key, value)
        case key
        when :type then "as :#{value}"
        when :array then "as an array"
        when :of then "of :#{value}"
        when :required then value ? "required" : "optional"
        when :virtual, :sensitive, :nullable then key.to_s
        else "#{OPTION_LABELS.fetch(key)} #{value.inspect}"
        end
      end

      def subject_name
        (@subject.respond_to?(:name) && @subject.name) || "the controller"
      end

      def path_label
        label_for(@path)
      end

      def label_for(path)
        path.include?(".") ? path.inspect : ":#{path}"
      end

      def action_label
        @action ? " for ##{@action}" : ""
      end
    end

    # Runs a declared contract against a payload and asserts on the outcome —
    # the behavioural counterpart to PermitParamMatcher, which asserts on the
    # declaration. Shares its subject and rule resolution, so `for_action` picks
    # the rule exactly as a request would and ambiguity fails loudly.
    class ParamsBehaviourMatcher
      def initialize(params, expect_accepted:)
        @params = params
        @expect_accepted = expect_accepted
        @expected_violations = []
        @action = nil
      end

      # -- chains -------------------------------------------------------------

      def for_action(action)
        @action = action.to_s
        self
      end

      # accept_params only: assert the cast, defaulted, transformed output.
      def returning(hash)
        @returning = hash
        self
      end

      # reject_params only: assert a particular violation is among those
      # recorded. Repeatable; the code is optional.
      def with_violation(param, code = nil)
        @expected_violations << { param: param.to_s, code: code&.to_s }
        self
      end

      # -- RSpec protocol -----------------------------------------------------

      def matches?(subject)
        @subject = PermitParamMatcher.new("").send(:resolve_subject, subject)
        rule = resolve_rule
        return false unless rule

        @violations, @result = run(rule)
        @expect_accepted ? accepted_ok? : rejected_ok?
      end

      def failure_message
        return "expected #{subject_name} to #{description}, but it #{@problem}" if @problem

        if @expect_accepted
          return "expected #{subject_name} to #{description}, but it rejected them: #{summary(@violations)}" unless @violations.empty?

          "expected #{subject_name} to #{description}, but it accepted them but returned #{@result.to_h.inspect}"
        else
          return "expected #{subject_name} to #{description}, but it accepted them, returning #{@result.to_h.inspect}" if @violations.empty?

          "expected #{subject_name} to #{description}, but the violations were: #{summary(@violations)}"
        end
      end

      def failure_message_when_negated
        verb = @expect_accepted ? "accept" : "reject"
        "expected #{subject_name} not to #{verb} those params#{action_label}, but it did"
      end

      def description
        label = @expect_accepted ? "accept those params" : "reject those params"
        label += action_label
        label += " with #{summary(@expected_violations)}" unless @expected_violations.empty?
        label += " returning #{@returning.inspect}" if @returning
        label
      end

      def supports_block_expectations?
        false
      end

      private

      def accepted_ok?
        return false unless @violations.empty?

        @returning.nil? || @result.to_h == ActiveSupport::HashWithIndifferentAccess.new(@returning).to_h
      end

      def rejected_ok?
        return false if @violations.empty?

        @expected_violations.all? do |expected|
          @violations.any? do |actual|
            actual[:param] == expected[:param] && (expected[:code].nil? || actual[:code] == expected[:code])
          end
        end
      end

      # A throwaway host carrying just this rule, forced to :enforce. The
      # question these matchers answer is what the CONTRACT says, not what the
      # current rollout mode does with it — so a monitor-mode rule still reports
      # its violations here.
      def run(rule)
        host = Class.new do
          include Permittable

          attr_accessor :params
        end
        host.permittable_contracts = [rule.merge(mode: :enforce).freeze]
        instance = host.new
        instance.params = @params
        action = @action || rule[:actions].first || "call"
        violations = instance.permittable_violations(action)
        result = violations.empty? ? instance.permitted_params(action) : nil
        [violations, result]
      end

      def resolve_rule
        if @action
          @subject.permit_rule_for(@action) || record_problem("has no contract covering ##{@action}")
        else
          contracts = @subject.permittable_contracts
          case contracts.length
          when 0 then record_problem("declares no contracts")
          when 1 then contracts.first
          else
            raise ArgumentError, "#{LABEL}: #{subject_name} declares #{contracts.length} contracts — " \
                                 "disambiguate with accept_params(...).for_action(:action)"
          end
        end
      end

      def record_problem(problem)
        @problem = problem
        nil
      end

      def summary(violations)
        violations.map { |v| v[:code] ? "#{v[:param]} (#{v[:code]})" : v[:param] }.join(", ")
      end

      def subject_name
        (@subject.respond_to?(:name) && @subject.name) || "the contract"
      end

      def action_label
        @action ? " for ##{@action}" : ""
      end
    end
  end
end

RSpec.configure { |config| config.include Permittable::Matchers } if defined?(RSpec) && RSpec.respond_to?(:configure)
