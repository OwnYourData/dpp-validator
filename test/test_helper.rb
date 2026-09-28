require "minitest/autorun"
require_relative "../lib/dpp_validator"
require_relative "support/test_certs"
require_relative "support/test_server"

# Base class for the tests copied from dpplint: Minitest::Test with the
# `test "name" do ... end` DSL of ActiveSupport::TestCase.
class DpplintTestCase < Minitest::Test
  def self.test(name, &block)
    define_method("test_#{name.gsub(/\s+/, '_')}", &block)
  end
end

# Base class for the tests of dpp-validator: local test servers, a client that
# trusts the test CA and short timeouts.
class ValidatorTestCase < DpplintTestCase
  NOW = Time.utc(2026, 9, 28, 12, 0, 0)
  DPP_ID = "did:oyd:zQmTest1".freeze
  PRODUCT_ID = "https://example.org/01/09520123456788/21/000001".freeze

  def setup
    @servers = []
  end

  def teardown
    @servers.each(&:stop)
  end

  def server(**options, &handler)
    TestServer.new(**options, &handler).tap { |s| @servers << s }
  end

  def plain_server(&handler)
    PlainTestServer.new(&handler).tap { |s| @servers << s }
  end

  def config(**overrides)
    DppValidator::Config.new(connect_timeout: 2, read_timeout: 1.5, cert_store: TestCerts.store, **overrides)
  end

  def service_for(base, features: %w[fine-granular-api], test_data: {})
    DppValidator::Service.new(
      "id" => "test-service", "name" => "Test service", "operator" => { "name" => "Test" },
      "api_base" => base, "features" => features, "credentials" => "none",
      "test_data" => { "dppId" => DPP_ID, "productId" => PRODUCT_ID, "elementIdPath" => "$.ProductIdentification" }.merge(test_data)
    )
  end

  def context_for(service, config: self.config)
    DppValidator::Checks::Context.new(
      service: service, config: config, client: DppValidator::Transport::Client.new(config),
      placeholders: DppValidator::Placeholders.for(service, now: NOW, random_id: "dpp-validator-missing")
    )
  end

  def run_check(check, base, config: self.config, **service_options)
    service = service_for(base, **service_options)
    klass = DppValidator::Checks.for(check["type"])
    klass.new(check, context_for(service, config: config)).call
  end

  def json(status, body, headers = {})
    [status, { "Content-Type" => "application/json" }.merge(headers), body.is_a?(String) ? body : JSON.generate(body)]
  end

  def assert_result(expected, outcome)
    assert_equal expected, outcome.result,
                 "result #{outcome.result}, reason: #{outcome.reason.inspect}, messages: #{outcome.messages.inspect}, details: #{outcome.details.inspect}"
  end

  def messages_text(outcome) = outcome.messages.map { |m| "#{m[:severity]}: #{m[:message]}" }
end
