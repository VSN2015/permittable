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

      def nullable
        @expected[:nullable] = true
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
        when :format then format_mismatch(field, value)
        # Compared cast, but reported as written.
        when :in then option_mismatch(field, :in, value) unless field.key?(:in) && field[:in] == cast_in(field, value)
        when :virtual, :sensitive, :nullable then "expected the field to be #{key}, but it is not" unless field[key]
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

      # `matching(:email)` asserts the preset by name, `matching(/re/)` the
      # Regexp itself.
      def format_mismatch(field, expected)
        return option_mismatch(field, :format, expected) unless expected.is_a?(Symbol)
        return if field[:format_name] == expected

        "expected format: :#{expected}, but the contract #{declared_format(field)}"
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
        @path.include?(".") ? @path.inspect : ":#{@path}"
      end

      def action_label
        @action ? " for ##{@action}" : ""
      end
    end
  end
end

RSpec.configure { |config| config.include Permittable::Matchers } if defined?(RSpec) && RSpec.respond_to?(:configure)
