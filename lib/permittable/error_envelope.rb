module Permittable
  # One home for the error response, in either of two shapes.
  #
  # `:envelope` (the default) is the gem's original shape: the host's
  # #render_error when the controller defines one (e.g. concerns_on_rails'
  # Respondable), otherwise the identical inline JSON.
  #
  # `:problem` renders RFC 9457 Problem Details — `application/problem+json`
  # with type/title/status/detail/instance members and the field violations as
  # an `errors` extension. Set it app-wide, because the error format of an API
  # is a property of the API rather than of any one contract:
  #
  #   # config/initializers/permittable.rb
  #   Permittable.error_format = :problem
  #   Permittable.problem_base_uri = "https://api.example.com/problems"
  #
  # Choosing `:problem` deliberately opts OUT of #render_error delegation: a
  # host envelope and a problem document are two answers to the same question,
  # and the explicit setting is the one to honour.
  module ErrorEnvelope
    module_function

    PROBLEM_MEDIA_TYPE = "application/problem+json".freeze

    # The two statuses this gem raises, plus the Rails 7.2+ spelling of 422.
    # Kept as a literal so a problem document can carry a numeric status
    # without activesupport-only hosts needing Rack; anything else defers to
    # Rack::Utils when the host has it.
    STATUS_CODES = { bad_request: 400, unprocessable_entity: 422, unprocessable_content: 422 }.freeze

    # A short human-readable summary of the problem TYPE (RFC 9457 §3.1.2), so
    # it describes the kind of failure, not this instance of it: a missing
    # `root:` means the request envelope itself is wrong, while a field
    # violation means a well-formed request said something invalid.
    PROBLEM_TYPES = {
      400 => ["malformed-request", "Malformed request"].freeze,
      422 => ["invalid-parameters", "Invalid parameters"].freeze
    }.freeze

    def render(controller, message:, status:, code: nil, details: nil)
      return render_problem(controller, message: message, status: status, details: details) if Permittable.error_format == :problem

      render_envelope(controller, message: message, status: status, code: code, details: details)
    end

    def render_envelope(controller, message:, status:, code: nil, details: nil)
      if controller.respond_to?(:render_error)
        # errors: only when there are details — a host may document its
        # render_error contract as `(message:, status:, code:)`, and an
        # unconditional errors: kwarg would break those implementations.
        kwargs = { message: message, code: code, status: status }
        kwargs[:errors] = details if details
        controller.render_error(**kwargs)
      else
        error = { message: message }
        error[:code] = code if code
        error[:details] = details if details
        controller.render(json: { success: false, error: error }, status: status)
      end
    end

    # Members are emitted in the order RFC 9457 documents them, so the wire
    # format is stable and readable. `instance` is omitted rather than guessed
    # when the host cannot name the request path (a params duck, a job).
    def render_problem(controller, message:, status:, details: nil)
      numeric = status_code(status)
      slug, title = PROBLEM_TYPES.fetch(numeric, ["invalid-parameters", "Invalid parameters"])
      problem = { type: problem_type(slug), title: title }
      problem[:status] = numeric if numeric
      problem[:detail] = message
      instance = request_path(controller)
      problem[:instance] = instance if instance
      problem[:errors] = details if details && !details.empty?
      controller.render(json: problem, status: status, content_type: PROBLEM_MEDIA_TYPE)
    end

    # RFC 9457: an absent `type` means "about:blank", so that is the honest
    # default until an app publishes documents to point at.
    def problem_type(slug)
      base = Permittable.problem_base_uri
      return "about:blank" unless base

      "#{base.to_s.chomp('/')}/#{slug}"
    end

    def status_code(status)
      return status if status.is_a?(Integer)

      symbol = status.to_sym
      STATUS_CODES[symbol] ||
        (defined?(Rack::Utils) && Rack::Utils::SYMBOL_TO_STATUS_CODE[symbol])
    end

    def request_path(controller)
      return nil unless controller.respond_to?(:request) && controller.request.respond_to?(:path)

      controller.request.path
    end
  end
end
