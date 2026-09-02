module Permittable
  # A contract without a controller — the same field DSL, coercion, defaults,
  # finalize, and violation vocabulary, callable on any Hash: webhook
  # payloads, job arguments, service-object inputs, CSV rows.
  #
  #   CreateUser = Permittable::Contract.define(root: :user) do
  #     required :email, :string, format: URI::MailTo::EMAIL_REGEXP
  #     optional :age,   :integer, in: 18..120
  #     optional :plan,  :string, in: %w[free pro], default: "free"
  #   end
  #
  #   result = CreateUser.call(payload)   # => Result
  #   result.valid?                       # => false
  #   result.violations                   # => [{ param: "user.age", code: "inclusion" }]
  #   result.params                       # validated HashWithIndifferentAccess, nil when invalid
  #
  #   CreateUser.call!(payload)           # params, or raises Permittable::InvalidParameters
  #
  # Differences from the controller concern, all deliberate:
  #   * A Contract always ENFORCES. Monitor mode is a request-rollout switch;
  #     standalone callers read the Result instead, so the app-wide
  #     `Permittable.mode` is ignored here.
  #   * The router's bookkeeping keys (controller/action/format) get no
  #     exemption from `unknown:` checking — standalone input has no router.
  #   * No memoization: every #call validates fresh, so one frozen Contract
  #     is safely reusable and shareable.
  #
  # Everything else carries over, including `sensitive:` log-redaction
  # registration, `invalid_parameters.permittable` instrumentation, 400
  # semantics for a missing `root:`, and `#json_schema` for documentation.
  class Contract
    ACTION = "call".freeze

    # The result of one #call: `params` is the cast, validated, defaulted
    # HashWithIndifferentAccess (nil when invalid); `violations` is the same
    # details array a controller's 422 would carry.
    Result = Struct.new(:params, :violations, keyword_init: true) do
      def valid?
        violations.empty?
      end

      def invalid?
        !valid?
      end
    end

    class << self
      alias define new
    end

    def initialize(root: false, unknown: :ignore, model: nil, desc: nil, &)
      @host_class = Class.new do
        include Permittable

        attr_accessor :params

        # Standalone input has no router, so nothing is exempt from the
        # unknown-keys check (the concern exempts controller/action/format
        # at the top level of request params).
        def permittable_check_unknown(fields, hash, path:, unknown:, top_level:, violations:) # rubocop:disable Lint/UnusedMethodArgument
          super(fields, hash, path: path, unknown: unknown, top_level: false, violations: violations)
        end

        # Instrumentation payload label (anonymous classes have no name).
        def permittable_controller_name
          "Permittable::Contract"
        end
      end
      @host_class.permit_params(root: root, unknown: unknown, model: model, mode: :enforce, desc: desc, &)
    end

    # The frozen rule — same introspectable data a controller's
    # `permit_rule_for` returns, readable by every contract consumer
    # (JsonSchema, OpenAPI, the RSpec matchers' internals).
    def rule
      @host_class.permittable_contracts.last
    end

    def call(input)
      Result.new(params: call!(input), violations: [].freeze)
    rescue InvalidParameters => e
      Result.new(params: nil, violations: e.details)
    end

    def call!(input)
      host = @host_class.new
      host.params = normalize_input(input)
      host.permitted_params(ACTION)
    end

    # The request-body schema for this contract — JSON Schema draft 2020-12,
    # identical to what the OpenAPI exporter emits for a controller rule.
    def json_schema
      JsonSchema.rule(rule)
    end

    private

    def normalize_input(input)
      return {} if input.nil?
      return input if input.is_a?(Hash) || input.respond_to?(:to_unsafe_h)

      raise ArgumentError, "#{LABEL}: Contract#call expects a Hash (got #{input.class})"
    end
  end
end
