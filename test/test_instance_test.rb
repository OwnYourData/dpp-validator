require_relative "test_helper"
require_relative "support/fake_dpp_service"
require "stringio"
require "tmpdir"

# Entries with check.mode test-instance-weekly: run in full on our own
# short-lived test instance, whose info file gives the API base, the test
# passport and the software version.
class TestInstanceTest < ValidatorTestCase
  SETUP = "https://github.com/OwnYourData/dpp-validator/tree/main/test-instances/basyx".freeze
  SEC_REASON = "The test instance runs without access control.".freeze

  def entry(**extra)
    CriteriaDir.research({ "mode" => "test-instance-weekly" },
                         "test_instance" => { "setup" => SETUP, "configuration" => "Current release, default configuration.",
                                              "not_applicable" => [{ "criterion" => "DPP-SEC-001", "reason" => SEC_REASON }] },
                         "features" => %w[fine-granular-api write-api historical-versions], **extra)
  end

  def info(api_base)
    { "service_id" => "basyx", "software" => "Example DPP API", "version" => "1.1.2",
      "release" => "https://example.org/releases/v1.1.2", "images" => ["example/dpp-api:1.1.2@sha256:abc"],
      "started_at" => "2026-09-28T11:59:00Z", "setup" => SETUP, "test_passport" => "https://example.org/sample-dpp.json",
      "api_base" => api_base,
      "test_data" => { "productId" => PRODUCT_ID, "dppId" => DPP_ID, "elementIdPath" => "$.ProductIdentification.ModelIdentifier" } }
  end

  def with_checkout(entries, &block)
    skip "no dpp-criteria checkout at #{CriteriaDir::SOURCE}" unless CriteriaDir.available?
    schema = File.read(File.join(CriteriaDir::SOURCE, "schema", "service.schema.json"))
    skip "dpp-criteria checkout without test instances" unless schema.include?("test-instance-weekly")
    CriteriaDir.with(entries, &block)
  end

  def cli(*argv, config: self.config)
    out = StringIO.new
    err = StringIO.new
    status = DppValidator::Cli.new(argv, out: out, err: err, config: config).call
    [status, out.string, err.string]
  end

  test "an entry on a test instance is checked in full every week and takes API base and test passport from the instance" do
    s = DppValidator::Service.new(entry.merge("id" => "basyx"))
    assert s.test_instance?
    assert s.checked?
    refute s.read_only?
    assert_equal "weekly", s.cadence
    assert_equal({ "DPP-SEC-001" => SEC_REASON }, s.not_applicable_on_test_instance)
    assert_nil s.api_base
    on = s.on_test_instance(info("http://basyx-dpp-api:8080/v1"))
    assert_equal "http://basyx-dpp-api:8080/v1", on.api_base
    assert_equal DPP_ID, on.test_data["dppId"]
    assert_equal({ "setup" => SETUP, "configuration" => "Current release, default configuration." }, s.to_h["test_instance"])
  end

  test "weekly cycle runs the entry in full on its test instance; tls criteria and listed criteria are not applicable" do
    api = server(protocols: %w[h2], &FakeDppService.handler(DPP_ID, PRODUCT_ID))
    plain = plain_server { [301, { "Location" => "https://localhost/" }, ""] }
    with_checkout("basyx" => entry, "gone" => entry) do |dir|
      instances = File.join(dir, "instances")
      FileUtils.mkdir_p(instances)
      File.write(File.join(instances, "basyx.json"), JSON.generate(info(api.url("/dpp/v1"))))
      out = File.join(dir, "out")
      done = DppValidator::Cycle.new(repository: DppValidator::CriteriaRepository.new(dir), cadence: "weekly", output_dir: out,
                                     config_for: ->(read_only) { config(http_port: plain.port, read_only: read_only) },
                                     out: StringIO.new, now: NOW, test_instances_dir: instances).call
      assert_equal ["basyx"], done[:runs]
      assert_equal 1, done[:errors].size
      assert_match(/gone: test instance not available/, done[:errors].first)
      refute File.exist?(File.join(out, "gone.json")), "an entry without a running test instance is not run"

      result = JSON.parse(File.read(File.join(out, "basyx.json")))
      assert_equal "test-instance", result["mode"]
      assert_equal %w[software version release images started_at setup test_passport test_data].sort, result["test_instance"].keys.sort
      assert_equal "1.1.2", result.dig("test_instance", "version")
      refute result["service"].key?("api_base"), "the internal API base is not published"
      refute_includes JSON.generate(result), api.url("/dpp/v1")
      by_id = result["criteria"].to_h { |c| [c["id"], c] }
      %w[DPP-DEX-002 DPP-DEX-003 DPP-DEX-005 DPP-DEX-006].each do |id|
        assert_equal %w[skipped not_applicable], [by_id[id]["result"], by_id[id]["reason_code"]], id
        assert_equal DppValidator::Runner::TEST_INSTANCE_TLS, by_id[id]["reason"]
      end
      assert_equal %w[skipped not_applicable], [by_id["DPP-SEC-001"]["result"], by_id["DPP-SEC-001"]["reason_code"]]
      assert_equal "checked on our own test instance. #{SEC_REASON}", by_id["DPP-SEC-001"]["reason"]
      assert_equal "passed", by_id["DPP-API-013"]["result"]
      assert_includes api.received.map(&:method), "POST", "a run on a test instance is in full"
    end
  end

  test "available-services.json and the pages name the test instance and its version" do
    s = DppValidator::Service.new(entry.merge("id" => "basyx", "name" => "Example DPP API", "url" => "https://basyx.example/"))
    result = { "run_at" => "2026-10-19T04:30:00Z", "mode" => "test-instance",
               "test_instance" => info("http://basyx-dpp-api:8080/v1").except("api_base"),
               "service" => s.to_h, "dpp_criteria" => { "commit" => "c5a0a5ce389ac662ae7612a1bc50d520c09991d9" },
               "summary" => { "text" => "10 of 10 automated checks passed", "passed" => 10, "failed" => 0, "warnings" => 2,
                              "skipped" => 5, "skipped_by_reason" => { "not_applicable" => 5 },
                              "proposed_not_counted" => { "text" => "0 of 0 automated checks passed", "failed" => 0 } },
               "criteria" => [] }
    available = DppValidator::Available.new(services: [s], results: { "basyx" => result }, lints: {},
                                            site_url: "https://pages.example/v", now: NOW).to_h
    validator = available["services"].first["validator"]
    assert_equal "test-instance", validator["mode"]
    assert_equal "weekly", validator["cadence"]
    assert_equal({ "software" => "Example DPP API", "version" => "1.1.2", "release" => "https://example.org/releases/v1.1.2" },
                 validator["test_instance"])
    assert_equal "10 of 10 automated checks passed", validator["summary_text"]
    pending = DppValidator::Available.new(services: [s], results: {}, lints: {}, site_url: "https://pages.example/v", now: NOW).to_h
    assert_equal({ "status" => "pending", "mode" => "test-instance", "cadence" => "weekly",
                   "details_url" => "https://pages.example/v/services/basyx.html" }, pending["services"].first["validator"])

    Dir.mktmpdir do |dir|
      input = File.join(dir, "in")
      FileUtils.mkdir_p(input)
      File.write(File.join(input, "basyx.json"), JSON.generate(result))
      out = File.join(dir, "site")
      DppValidator::Site.new(results_dir: input, output_dir: out, services: [s], now: NOW).build
      index = File.read(File.join(out, "index.html"), encoding: "UTF-8")
      assert_includes index, "10 of 10 passed · 2 warnings · full, weekly, on our own test instance (version 1.1.2)"
      assert_includes index, "short-lived test instance of our own"
      detail = File.read(File.join(out, "services", "basyx.html"), encoding: "UTF-8")
      assert_includes detail, %(<dt>Test instance</dt><dd>Current release, default configuration. <a href="#{SETUP}">Setup</a></dd>)
      assert_includes detail, %(on our own test instance: Example DPP API 1.1.2 (<a href="https://example.org/releases/v1.1.2">release</a>))
      refute_includes detail, "basyx-dpp-api"
    end
  end

  test "run needs the info file of the test instance and is never read-only there; services lists the test instances" do
    api = server(protocols: %w[h2], &FakeDppService.handler(DPP_ID, PRODUCT_ID))
    plain = plain_server { [301, { "Location" => "https://localhost/" }, ""] }
    with_checkout("basyx" => entry, "res" => CriteriaDir.research({ "mode" => "read-only-weekly" }, "api_base" => "https://res.example/v1")) do |dir|
      assert_equal [0, "basyx\n"], cli("services", "--criteria", dir, "--test-instances").first(2)
      assert_equal [0, "basyx\nres\n"], cli("services", "--criteria", dir, "--cadence", "weekly").first(2)

      status, _out, err = cli("run", "--service", "basyx", "--criteria", dir)
      assert_equal 2, status
      assert_match(/basyx is checked on our own test instance: --test-instance FILE is required/, err)

      info_file = File.join(dir, "basyx-info.json")
      File.write(info_file, JSON.generate(info(api.url("/dpp/v1"))))
      status, _out, err = cli("run", "--service", "basyx", "--criteria", dir, "--test-instance", info_file, "--read-only")
      assert_equal 2, status
      assert_match(/--read-only does not apply/, err)
      status, _out, err = cli("run", "--service", "basyx", "--criteria", dir, "--test-instance", File.join(dir, "missing.json"))
      assert_equal 2, status
      assert_match(/test instance info/, err)

      output = File.join(dir, "basyx.json")
      status, out, err = cli("run", "--service", "basyx", "--criteria", dir, "--test-instance", info_file, "--output", output,
                             config: config(http_port: plain.port))
      assert_equal 0, status, err
      assert_match(/our own test instance, Example DPP API 1\.1\.2/, out)
      assert_equal "test-instance", JSON.parse(File.read(output))["mode"]
    end
  end
end
