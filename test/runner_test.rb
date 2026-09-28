require_relative "test_helper"
require_relative "support/fake_dpp_service"
require "tmpdir"
require "fileutils"

# End to end: the criteria of a dpp-criteria checkout (DPP_CRITERIA_DIR)
# against a local service that behaves as they expect.
class RunnerTest < ValidatorTestCase
  CRITERIA_DIR = ENV.fetch("DPP_CRITERIA_DIR", "/opt/dpp-criteria")
  SERVICE_CRITERIA = %w[DPP-API-007 DPP-API-013 DPP-API-014 DPP-API-015 DPP-API-016 DPP-API-019 DPP-API-020 DPP-API-021
                        DPP-DEX-002 DPP-DEX-003 DPP-DEX-004 DPP-DEX-005 DPP-DEX-006 DPP-OPS-006 DPP-SEC-001].freeze

  def setup
    super
    skip "no dpp-criteria checkout at #{CRITERIA_DIR}" unless File.directory?(File.join(CRITERIA_DIR, "criteria"))
    @plain = plain_server { [301, { "Location" => "https://localhost/" }, ""] }
    @tls = server(protocols: %w[h2], tls: %w[1.2 1.3], &FakeDppService.handler(DPP_ID, PRODUCT_ID))
  end

  def service(**overrides)
    service_for(@tls.url("/dpp/v1"), features: %w[fine-granular-api write-api historical-versions],
                                      test_data: { "elementIdPath" => "$.ProductIdentification.ModelIdentifier" }, **overrides)
  end

  def run_with(repository, service = self.service)
    DppValidator::Runner.new(repository: repository, service: service, config: config(http_port: @plain.port), now: NOW,
                             random_id: "dpp-validator-missing").run
  end

  def results(report) = report.results.to_h { |r| [r["id"], r] }

  # A copy of the checkout in which the block may change criteria.
  def copy_of_checkout
    Dir.mktmpdir do |dir|
      %w[criteria schema services].each { |d| FileUtils.cp_r(File.join(CRITERIA_DIR, d), dir) }
      File.write(File.join(dir, "COMMIT"), "test-commit\n")
      yield dir
    end
  end

  def edit(dir, id)
    file = Dir[File.join(dir, "criteria", "*", "#{id}.yaml")].first
    data = YAML.safe_load(File.read(file))
    yield data
    File.write(file, YAML.dump(data))
  end

  test "all service criteria of the checkout against a service that behaves as expected" do
    report = run_with(DppValidator::CriteriaRepository.new(CRITERIA_DIR))
    by_id = results(report)
    assert_equal SERVICE_CRITERIA, by_id.keys
    expected_skips = { "DPP-API-016" => /automated-auth/, "DPP-OPS-006" => /self-declared/ }
    expected_skips["DPP-DEX-003"] = /SSL 3\.0 not tested/ unless DppValidator::Transport::TlsVersions.offerable?("ssl3")
    by_id.each do |id, r|
      if expected_skips[id]
        assert_equal "skipped", r["result"], id
        assert_match expected_skips[id], r["reason"], id
      else
        assert_equal "passed", r["result"], "#{id}: #{r.inspect}"
      end
    end
    assert report.not_run.any? { |n| n["id"] == "DPP-DAT-014" }
  end

  test "only active criteria count in N of M; proposed ones are reported separately" do
    report = run_with(DppValidator::CriteriaRepository.new(CRITERIA_DIR))
    assert report.results.all? { |r| r["status"] == "proposed" }, "dpp-criteria 4b17bb8 has only proposed criteria"
    assert_equal "0 of 0 automated checks passed", report.summary["text"]
    passed = report.results.count { |r| %w[passed warning].include?(r["result"]) }
    counted = report.results.count { |r| %w[passed warning failed].include?(r["result"]) }
    assert_equal "#{passed} of #{counted} automated checks passed", report.proposed_summary["text"]
    refute report.results.any? { |r| r["counted"] }

    copy_of_checkout do |dir|
      edit(dir, "DPP-DEX-004") { |d| d["status"] = "active" }
      edit(dir, "DPP-API-013") { |d| d["status"] = "active"; d["check"]["steps"][0]["expect"]["status"] = [201] }
      report = run_with(DppValidator::CriteriaRepository.new(dir))
      assert_equal "1 of 2 automated checks passed", report.summary["text"]
      assert_equal "test-commit", report.to_h["dpp_criteria"]["commit"]
      assert_equal [true, true], results(report).values_at("DPP-DEX-004", "DPP-API-013").map { |r| r["counted"] }
    end
  end

  test "features not declared, schema errors and unknown check types give skipped" do
    copy_of_checkout do |dir|
      edit(dir, "DPP-API-020") { |d| d["check"]["unknown"] = true }
      report = run_with(DppValidator::CriteriaRepository.new(dir), service(features: []))
      by_id = results(report)
      assert_match(/does not declare fine-granular-api/, by_id["DPP-API-021"]["reason"])
      assert_match(/does not declare historical-versions/, by_id["DPP-API-019"]["reason"])
      assert_match(/does not match schema\/criterion\.schema\.json/, by_id["DPP-API-020"]["reason"])
    end
  end

  test "a service that answers HTTP/1.1 and does not evaluate JSONPath" do
    loose = server(protocols: %w[h2 http/1.1 http/1.0]) do |r|
      if r.path.include?("/elements/")
        json(404, { "message" => "unknown element" })
      else
        FakeDppService.handler(DPP_ID, PRODUCT_ID).call(r)
      end
    end
    report = run_with(DppValidator::CriteriaRepository.new(CRITERIA_DIR), service_for(loose.url("/dpp/v1"), features: %w[fine-granular-api]))
    by_id = results(report)
    assert_equal "failed", by_id["DPP-DEX-006"]["result"]
    assert_equal "failed", by_id["DPP-API-021"]["result"]
    assert_match(/step 1 .*HTTP status is 404, expected 200/, by_id["DPP-API-021"]["messages"].first["message"])
  end
end
