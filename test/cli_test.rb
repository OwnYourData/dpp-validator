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
        "entry" => { "source" => "operator", "as_of" => "2026-10-18" }, "licence" => { "text" => "MIT", "spdx" => ["MIT"] },
        "check" => { "mode" => "full-daily" },
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
      assert_equal %w[validator notice service run_at mode dpp_criteria summary criteria not_run], result.keys
      assert_equal "full", result["mode"]
      assert_match(/\A\h{40}(-dirty)?\z|\Aunknown\z/, result["dpp_criteria"]["commit"])
      assert_equal "local-test", result["service"]["id"]
      entry = result["criteria"].find { |c| c["id"] == "DPP-API-013" }
      assert_equal %w[id version status title level target method check_type result messages details counted], entry.keys - ["description_url"]
      assert_match(%r{/criteria/README\.md#dpp-api-013\z}, entry["description_url"]) if entry.key?("description_url")
    end
  end

  test "run --read-only sends only GET, HEAD and OPTIONS and says so" do
    skip "no dpp-criteria checkout at #{CRITERIA_DIR}" unless File.directory?(File.join(CRITERIA_DIR, "criteria"))
    tls = server(protocols: %w[h2], &FakeDppService.handler(DPP_ID, PRODUCT_ID))
    plain = plain_server { [301, { "Location" => "https://localhost/" }, ""] }
    Dir.mktmpdir do |dir|
      service_file = File.join(dir, "unlisted.yaml")
      File.write(service_file, YAML.dump(
        "id" => "unlisted-test", "name" => "Unlisted test", "operator" => { "name" => "Test" }, "contact" => "test@example.org",
        "entry" => { "source" => "operator", "as_of" => "2026-10-18" }, "licence" => { "text" => "MIT", "spdx" => ["MIT"] },
        "check" => { "mode" => "full-daily" },
        "api_base" => tls.url("/dpp/v1"), "features" => %w[fine-granular-api], "not_implemented" => %w[write-api historical-versions],
        "test_data" => { "productId" => PRODUCT_ID, "dppId" => DPP_ID, "elementIdPath" => "$.ProductIdentification.ModelIdentifier" },
        "credentials" => "none", "listed_since" => "2026-10-09"
      ))
      output = File.join(dir, "result.json")
      status, out, err = cli("run", "--service", service_file, "--criteria", CRITERIA_DIR, "--output", output, "--read-only",
                             config: config(http_port: plain.port))
      assert_equal 0, status, err
      assert_match(/^read-only run: only GET, HEAD and OPTIONS requests were sent$/, out)
      assert_match(/skipped \(not_sent\): read-only run/, out)
      result = JSON.parse(File.read(output))
      assert_equal "read-only", result["mode"]
      assert_equal %w[GET], tls.received.map(&:method).uniq
      assert_equal "not_implemented", result["criteria"].find { |c| c["id"] == "DPP-API-019" }["reason_code"]
    end
  end

  test "run checks research entries read-only and refuses entries that are not checked" do
    skip "no dpp-criteria checkout at #{CRITERIA_DIR}" unless CriteriaDir.available?
    tls = server(protocols: %w[h2], &FakeDppService.handler(DPP_ID, PRODUCT_ID))
    plain = plain_server { [301, { "Location" => "https://localhost/" }, ""] }
    entries = {
      "res" => CriteriaDir.research({ "mode" => "read-only-weekly" }, "api_base" => tls.url("/dpp/v1"),
                                    "test_data" => { "productId" => PRODUCT_ID, "dppId" => DPP_ID }),
      "none" => CriteriaDir.research({ "mode" => "none", "reason" => "no_public_instance" })
    }
    CriteriaDir.with(entries) do |dir|
      output = File.join(dir, "res.json")
      status, out, err = cli("run", "--service", "res", "--criteria", dir, "--output", output, config: config(http_port: plain.port))
      assert_equal 0, status, err
      assert_match(/^read-only run/, out)
      assert_equal "read-only", JSON.parse(File.read(output))["mode"]
      assert_equal %w[GET], tls.received.map(&:method).uniq
      status, _out, err = cli("run", "--service", "none", "--criteria", dir)
      assert_equal 2, status
      assert_match(/none is not checked \(check.mode none, reason no_public_instance\)/, err)
    end
  end

  test "services --cadence lists the entries whose service is run daily or weekly" do
    skip "no dpp-criteria checkout at #{CRITERIA_DIR}" unless CriteriaDir.available?
    entries = {
      "op" => CriteriaDir.operator("https://api.example/v1"),
      "res" => CriteriaDir.research({ "mode" => "read-only-weekly" }, "api_base" => "https://res.example/v1"),
      "none" => CriteriaDir.research({ "mode" => "none", "reason" => "no_public_instance" })
    }
    CriteriaDir.with(entries) do |dir|
      assert_equal [0, "op\n"], cli("services", "--criteria", dir, "--cadence", "daily").first(2)
      assert_equal [0, "res\n"], cli("services", "--criteria", dir, "--cadence", "weekly").first(2)
      assert_equal [0, "none\nop\nres\n"], cli("services", "--criteria", dir).first(2)
      assert_equal 2, cli("services", "--criteria", dir, "--cadence", "hourly").first
    end
  end

  test "site writes the pages and available-services.json from the entries" do
    skip "no dpp-criteria checkout at #{CRITERIA_DIR}" unless CriteriaDir.available?
    entries = { "none" => CriteriaDir.research({ "mode" => "none", "reason" => "no_public_instance" }) }
    CriteriaDir.with(entries) do |dir|
      results = File.join(dir, "results")
      FileUtils.mkdir_p(results)
      status, out, err = cli("site", "--criteria", dir, "--results", results, "--output", File.join(dir, "site"),
                             "--this-service", "none", "--site-url", "https://pages.example/x/")
      assert_equal 0, status, err
      assert_match(/1 service\(s\) written/, out)
      data = JSON.parse(File.read(File.join(dir, "site", "available-services.json")))
      assert_equal true, data["services"].first["this_service"]
      assert_equal({ "status" => "no_public_instance" }, data["services"].first["validator"])
      assert File.file?(File.join(dir, "site", "services", "none.html"))
    end
  end

  test "usage and configuration errors exit with 2" do
    assert_equal 2, cli("frobnicate").first
    assert_equal 2, cli("run", "--criteria", "/nonexistent").first
    status, _out, err = cli("run", "--service", "x", "--criteria", "/nonexistent")
    assert_equal 2, status
    assert_match(/not a dpp-criteria checkout/, err)
    status, _out, err = cli("cycle", "--cadence", "daily", "--history", "/nonexistent/runs")
    assert_equal 2, status
    assert_match(%r{--history /nonexistent/runs is not a directory}, err)
  end
end
