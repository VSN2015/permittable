module Permittable
  # One home for the error envelope: prefer the host's #render_error when the
  # controller defines one (e.g. concerns_on_rails' Respondable), otherwise
  # render the identical inline shape — and the single place to change when
  # e.g. an RFC 9457 problem+json mode lands.
  module ErrorEnvelope
    module_function

    def render(controller, message:, status:, code: nil, details: nil)
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
  end
end
