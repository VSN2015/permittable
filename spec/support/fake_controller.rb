require "active_support/hash_with_indifferent_access"

# Lightweight, dependency-free test harness. The concern only touches
# `params` (plus `render` through the error envelope), so most specs don't
# need a real Rails stack — the real-ActionController behaviors go through
# IntegrationHarness instead.
class FakeResponse
  attr_reader :headers
  attr_accessor :status, :body, :content_type

  def initialize
    @headers = {}
    @status = 200
  end

  def set_header(key, value)
    @headers[key] = value
  end
end

class FakeController
  attr_accessor :params, :response
  attr_reader :rendered

  def initialize(params: {})
    @params = ActiveSupport::HashWithIndifferentAccess.new(params)
    @response = FakeResponse.new
    @rendered = nil
  end

  # Stand-in for ActionController::Base#render. Captures what would have
  # been rendered so specs can assert on the json body / status.
  def render(options)
    @rendered = options
  end
end
