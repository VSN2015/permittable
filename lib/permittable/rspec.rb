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

      def initialize(path)
        @path = path.to_s
        @action = nil
        @expected = {}
        @mismatches = []
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

      # -- RSpec protocol ---------------------------------------------------

      def matches?(subject)
        @subject = resolve_subject(subject)
        rule = resolve_rule(@subject)
        return false unless rule

        @field = resolve_field(rule[:fields], @path.split("."))
        return false unless @field

        @mismatches = collect_mismatches(@field)
        @mismatches.empty?
      end

      def failure_message
        return "expected #{subject_name} to permit #{path_label}#{action_label}, but it #{@problem}" if @problem

        if @field.nil?
          declared = (@missing_among || []).map { |f| f[:name] }.join(", ")
          return "expected #{subject_name} to permit #{path_label}#{action_label}, " \
                 "but it is not declared (declared: #{declared})"
        end

        "expected #{subject_name} to permit #{path_label}#{action_label}, but:\n  #{@mismatches.join("\n  ")}"
      end

      def failure_message_when_negated
        "expected #{subject_name} not to permit #{path_label}#{action_label}, but the contract declares it"
      end

      def description
        descriptors = @expected.filter_map { |key, value| describe_check(key, value) }
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
      # alike, since both carry their sub-fields under :fields.
      def resolve_field(fields, segments)
        name = segments.first.to_sym
        field = fields.find { |f| f[:name] == name }
        if field.nil?
          @missing_among = fields
          return nil
        end
        return field if segments.length == 1

        resolve_field(field[:fields] || [], segments.drop(1))
      end

      def collect_mismatches(field)
        @expected.filter_map { |key, value| check_mismatch(field, key, value) }
      end

      def check_mismatch(field, key, value)
        case key
        when :type then type_mismatch(field, value)
        when :array then "expected an array field, but it is declared with `#{field[:kind]}`" unless field[:kind] == :array
        when :of then "expected an array of :#{value}, but it is of: :#{field[:of]}" unless field[:of] == value
        when :required then required_mismatch(field, value)
        when :virtual, :sensitive then "expected the field to be #{key}, but it is not" unless field[key]
        else option_mismatch(field, key, value)
        end
      end

      def type_mismatch(field, type)
        if field[:kind] == :array
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

      def option_mismatch(field, key, value)
        return if field.key?(key) && field[key] == value

        label = OPTION_LABELS.fetch(key)
        declared = field.key?(key) ? "declares #{label} #{field[key].inspect}" : "does not declare #{label}"
        "expected #{label} #{value.inspect}, but the contract #{declared}"
      end

      def describe_check(key, value)
        case key
        when :type then "as :#{value}"
        when :array then "as an array"
        when :of then "of :#{value}"
        when :required then value ? "required" : "optional"
        when :virtual, :sensitive then key.to_s
        else "#{OPTION_LABELS.fetch(key)} #{value.inspect}"
        end
      end

      def subject_name
        (@subject.respond_to?(:name) && @subject.name) || "the controller"
      end

      def path_label
        @path.include?(".") ? @path.inspect : ":#{@path}"
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
