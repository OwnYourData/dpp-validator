require_relative "test_helper"
require_relative "support/fake_dpp_service"
require "tmpdir"
require "stringio"

class CliTest < ValidatorTestCase
  CRITERIA_DIR = ENV.fetch("DPP_CRITERIA_DIR", "/opt/dpp-criteria")

  def cli(*argv, config: self.config)
    out = StringIO.new
    err = StringIO.new
    status = DppValidator::Cli.new(argv, out: out, err: err, config: config).call
    [status, out.string, err.string]
  end

  test "run writes a JSON result and prints the summary" do
    skip "no dpp-criteria checkout at #{CRITERIA_DIR}" unless File.directory?(File.join(CRITERIA_DIR, "criteria"))
    tls = server(protocols: %w[h2], &FakeDppService.handler(DPP_ID, PRODUCT_ID))
    plain = plain_server { [301, { "Location" => "https://localhost/" }, ""] }
    Dir.mktmpdir do |dir|
      service_file = File.join(dir, "local.yaml")
      File.write(service_file, YAML.dump(
        "id" => "local-test", "name" => "Local test", "operator" => { "name" => "Test" }, "contact" => "test@example.org",
        "api_base" => tls.url("/dpp/v1"), "features" => %w[fine-granular-api],
        "test_data" => { "productId" => PRODUCT_ID, "dppId" => DPP_ID, "elementIdPath" => "$.ProductIdentification.ModelIdentifier" },
        "credentials" => "none", "listed_since" => "2026-10-01"
      ))
      output = File.join(dir, "out", "result.json")
      status, out, err = cli("run", "--service", service_file, "--criteria", CRITERIA_DIR, "--output", output,
                             config: config(http_port: plain.port))
      assert_equal 0, status, err
      assert_match(/^\d+ of \d+ automated checks passed \(active criteria\)$/, out)
      assert_match(/^proposed, not counted: \d+ of \d+ automated checks passed/, out)
      refute_match(/conform|certified/i, out.sub(DppValidator::Report::NOTICE, ""))
      result = JSON.parse(File.read(output))
      assert_equal %w[validator notice service run_at dpp_criteria summary criteria not_run], result.keys
      assert_match(/\A\h{40}(-dirty)?\z|\Aunknown\z/, result["dpp_criteria"]["commit"])
      assert_equal "local-test", result["service"]["id"]
      entry = result["criteria"].find { |c| c["id"] == "DPP-API-013" }
      assert_equal %w[id version status title level target method check_type result messages details counted], entry.keys - ["description_url"]
      assert_match(%r{/criteria/README\.md#dpp-api-013\z}, entry["description_url"]) if entry.key?("description_url")
    end
  end

  test "usage and configuration errors exit with 2" do
    assert_equal 2, cli("frobnicate").first
    assert_equal 2, cli("run", "--criteria", "/nonexistent").first
    status, _out, err = cli("run", "--service", "x", "--criteria", "/nonexistent")
    assert_equal 2, status
    assert_match(/not a dpp-criteria checkout/, err)
  end
end
