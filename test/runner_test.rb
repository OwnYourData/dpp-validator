require_relative "test_helper"
require_relative "support/fake_dpp_service"
require "tmpdir"
require "fileutils"

# End to end: the criteria of a dpp-criteria checkout (DPP_CRITERIA_DIR)
# against a local service that behaves as they expect.
class RunnerTest < ValidatorTestCase
  CRITERIA_DIR = ENV.fetch("DPP_CRITERIA_DIR", "/opt/dpp-criteria")
  SERVICE_CRITERIA = %w[DPP-ACC-003 DPP-ACC-006 DPP-ACC-008 DPP-ACC-012 DPP-ACC-014 DPP-ACC-015 DPP-API-007 DPP-API-013
                        DPP-API-014 DPP-API-015 DPP-API-016 DPP-API-019 DPP-API-020 DPP-API-021 DPP-API-022 DPP-API-023
                        DPP-BAT-003 DPP-BCK-006 DPP-DEX-002 DPP-DEX-003 DPP-DEX-004 DPP-DEX-005 DPP-DEX-006 DPP-DGA-001
                        DPP-OPS-006 DPP-SEC-001 DPP-SEC-022 DPP-STO-015 DPP-STO-017 DPP-STO-019].freeze
  # Criteria that need the controlled test element and run without credentials.
  ACCESS_CRITERIA = %w[DPP-ACC-006 DPP-ACC-012 DPP-STO-017].freeze
  # Criteria with a step whose method a read-only run does not send.
  WRITING_CRITERIA = %w[DPP-API-007 DPP-API-015 DPP-SEC-001].freeze

  def setup
    super
    skip "no dpp-criteria checkout at #{CRITERIA_DIR}" unless File.directory?(File.join(CRITERIA_DIR, "criteria"))
    @plain = plain_server { [301, { "Location" => "https://localhost/" }, ""] }
    @tls = server(protocols: %w[h2], tls: %w[1.2 1.3], &FakeDppService.handler(DPP_ID, PRODUCT_ID))
  end

  def service(**overrides) = service_at(@tls.url("/dpp/v1"), **overrides)

  def service_at(base, **overrides)
    service_for(base, features: %w[fine-granular-api write-api historical-versions access-levels],
                      test_data: { "elementIdPath" => "$.ProductIdentification.ModelIdentifier",
                                   "controlledElementId" => FakeDppService::CONTROLLED,
                                   "controlledElementIdPath" => "$.#{FakeDppService::CONTROLLED}" }, **overrides)
  end

  def run_with(repository, service = self.service, read_only: false)
    DppValidator::Runner.new(repository: repository, service: service, config: config(http_port: @plain.port, read_only: read_only),
                             now: NOW, random_id: "dpp-validator-missing").run
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
    expected_skips = { "DPP-API-016" => [/automated-auth/, "needs_credentials"], "DPP-ACC-003" => [/automated-auth/, "needs_credentials"],
                       "DPP-OPS-006" => [/self-declared/, "not_evaluated"], "DPP-ACC-008" => [/self-declared/, "not_evaluated"],
                       "DPP-ACC-014" => [/self-declared/, "not_evaluated"], "DPP-ACC-015" => [/self-declared/, "not_evaluated"],
                       "DPP-BAT-003" => [/battery/, "not_applicable"], "DPP-BCK-006" => [/self-declared/, "not_evaluated"],
                       "DPP-DGA-001" => [/self-declared/, "not_evaluated"], "DPP-SEC-022" => [/self-declared/, "not_evaluated"],
                       "DPP-STO-015" => [/backup-provider/, "not_applicable"], "DPP-STO-019" => [/backup-provider/, "not_applicable"] }
    by_id.each do |id, r|
      if expected_skips[id]
        assert_equal "skipped", r["result"], id
        assert_match expected_skips[id][0], r["reason"], id
        assert_equal expected_skips[id][1], r["reason_code"], id
      else
        assert_equal "passed", r["result"], "#{id}: #{r.inspect}"
      end
    end
    assert report.not_run.any? { |n| n["id"] == "DPP-DAT-014" }
    assert_equal "full", report.to_h["mode"]
    assert_equal({ "needs_credentials" => 2, "not_evaluated" => 7, "not_applicable" => 3 }, report.proposed_summary["skipped_by_reason"])
  end

  test "a back-up provider: criteria that compare with the resolved passport are skipped, not passed" do
    report = run_with(DppValidator::CriteriaRepository.new(CRITERIA_DIR),
                      service(features: %w[fine-granular-api write-api historical-versions access-levels backup-provider]))
    by_id = results(report)
    %w[DPP-STO-015 DPP-STO-019].each do |id|
      assert_equal "skipped", by_id[id]["result"], id
      assert_equal "not_evaluated", by_id[id]["reason_code"], id
      assert_match(/compare_with_resolved is not evaluated in this version/, by_id[id]["reason"], id)
    end
  end

  test "read-only run: criteria with other methods are skipped as not_sent, nothing but GET, HEAD and OPTIONS is sent" do
    report = run_with(DppValidator::CriteriaRepository.new(CRITERIA_DIR), read_only: true)
    by_id = results(report)
    WRITING_CRITERIA.each do |id|
      assert_equal "skipped", by_id[id]["result"], id
      assert_equal "not_sent", by_id[id]["reason_code"], id
      assert_match(/read-only run: not sent, the criterion needs step \d+ (POST|PATCH)/, by_id[id]["reason"], id)
    end
    assert_equal "passed", by_id["DPP-API-022"]["result"]
    assert_equal "passed", by_id["DPP-API-013"]["result"]
    assert_equal %w[GET], @tls.received.map(&:method).uniq
    assert_equal "read-only", report.to_h["mode"]
    assert_match(/read-only run: only GET, HEAD and OPTIONS/, report.to_text)
  end

  test "a read-only client refuses other methods before connecting" do
    client = DppValidator::Transport::Client.new(config(read_only: true))
    error = assert_raises(DppValidator::Error) { client.request(@tls.url("/dpp/v1/dpps"), method: "POST", body: "{}") }
    assert_match(/read-only run: POST/, error.message)
    assert_empty @tls.received
  end

  test "results link to the description in criteria/README.md of the commit, if the checkout has one" do
    copy_of_checkout do |dir|
      File.write(File.join(dir, "COMMIT"), "#{'a' * 40}\n")
      FileUtils.rm_f(File.join(dir, "criteria", "README.md"))
      refute results(run_with(DppValidator::CriteriaRepository.new(dir)))["DPP-API-013"].key?("description_url")

      File.write(File.join(dir, "criteria", "README.md"), "# DPP criteria catalogue\n")
      assert_equal "https://github.com/OwnYourData/dpp-criteria/blob/#{'a' * 40}/criteria/README.md#dpp-api-013",
                   results(run_with(DppValidator::CriteriaRepository.new(dir)))["DPP-API-013"]["description_url"]
    end
  end

  test "only active criteria count in N of M; proposed ones are reported separately" do
    copy_of_checkout do |dir|
      Dir[File.join(dir, "criteria", "*", "*.yaml")].each do |file|
        data = YAML.safe_load(File.read(file))
        data["status"] = "proposed"
        File.write(file, YAML.dump(data))
      end
      report = run_with(DppValidator::CriteriaRepository.new(dir))
      assert_equal "0 of 0 automated checks passed", report.summary["text"]
      passed = report.results.count { |r| %w[passed warning].include?(r["result"]) }
      counted = report.results.count { |r| %w[passed warning failed].include?(r["result"]) }
      assert_equal "#{passed} of #{counted} automated checks passed", report.proposed_summary["text"]
      refute report.results.any? { |r| r["counted"] }

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
      assert_equal "not_applicable", by_id["DPP-API-021"]["reason_code"]
      assert_match(/does not declare historical-versions/, by_id["DPP-API-019"]["reason"])
      assert_match(/does not match schema\/criterion\.schema\.json/, by_id["DPP-API-020"]["reason"])
      assert_equal "not_evaluated", by_id["DPP-API-020"]["reason_code"]
    end
  end

  test "features the service lists under not_implemented give not_implemented instead of not_applicable" do
    report = run_with(DppValidator::CriteriaRepository.new(CRITERIA_DIR),
                      service(features: %w[fine-granular-api], not_implemented: %w[write-api historical-versions]))
    by_id = results(report)
    assert_equal "not_implemented", by_id["DPP-API-019"]["reason_code"]
    assert_match(/lists historical-versions as not implemented/, by_id["DPP-API-019"]["reason"])
    assert_equal "not_implemented", by_id["DPP-API-016"]["reason_code"]
    assert_equal %w[write-api historical-versions], report.to_h.dig("service", "not_implemented")
  end

  test "a service that delivers the controlled test element without credentials" do
    leaking = server(protocols: %w[h2]) do |r|
      if r.path.include?("/elements/%24.#{FakeDppService::CONTROLLED}")
        json(200, "\"secret\"")
      else
        status, headers, body = FakeDppService.handler(DPP_ID, PRODUCT_ID).call(r)
        value = JSON.parse(body) rescue nil
        if status == 200 && value.is_a?(Hash) && value.key?("digitalProductPassportId")
          if value["elements"]
            value["elements"] << { "elementId" => FakeDppService::CONTROLLED, "objectType" => "SingleValuedDataElement", "value" => "secret" }
          else
            value[FakeDppService::CONTROLLED] = "secret"
          end
          body = JSON.generate(value)
        end
        [status, headers, body]
      end
    end
    report = run_with(DppValidator::CriteriaRepository.new(CRITERIA_DIR), service_at(leaking.url("/dpp/v1")))
    by_id = results(report)
    ACCESS_CRITERIA.each { |id| assert_equal "failed", by_id[id]["result"], "#{id}: #{by_id[id].inspect}" }
  end

  test "a service without access levels: the access criteria are not_applicable or not_implemented" do
    by_id = results(run_with(DppValidator::CriteriaRepository.new(CRITERIA_DIR), service(features: %w[fine-granular-api historical-versions])))
    ACCESS_CRITERIA.each { |id| assert_equal %w[skipped not_applicable], by_id[id].values_at("result", "reason_code"), id }
    by_id = results(run_with(DppValidator::CriteriaRepository.new(CRITERIA_DIR),
                             service(features: %w[fine-granular-api historical-versions], not_implemented: %w[access-levels])))
    ACCESS_CRITERIA.each { |id| assert_equal %w[skipped not_implemented], by_id[id].values_at("result", "reason_code"), id }
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

  # Test vectors of DPP-ACC-012 (version 2): the answer to a fine-granular read
  # of the controlled test element without credentials.
  test "DPP-ACC-012: 401 with a challenge passes, 401 without one and 403 give warnings, 200 and 404 fail" do
    criterion = DppValidator::CriteriaRepository.new(CRITERIA_DIR).criteria.find { |c| c.id == "DPP-ACC-012" }
    assert_operator criterion["version"], :>=, 2
    path = "/dpp/v1/dpps/#{DppValidator::Placeholders.percent_encode(DPP_ID)}/elements/%24.#{FakeDppService::CONTROLLED}"
    vectors = [
      [401, { "WWW-Authenticate" => "Bearer" }, "passed", []],
      [401, { "WWW-Authenticate" => 'Bearer error="invalid_token"' }, "passed", []],
      [401, {}, "warning", ["warning: step 1 (GET /dpps/{dppId}/elements/{controlledElementIdPath}): header WWW-Authenticate is missing"]],
      [403, {}, "warning", ["warning: step 1 (GET /dpps/{dppId}/elements/{controlledElementIdPath}): HTTP status 403 is listed in warn_if_status"]],
      [404, {}, "failed", ["error: step 1 (GET /dpps/{dppId}/elements/{controlledElementIdPath}): HTTP status is 404, expected 401"]],
      [200, {}, "failed", ["error: step 1 (GET /dpps/{dppId}/elements/{controlledElementIdPath}): HTTP status is 200, expected 401"]]
    ]
    vectors.each do |status, headers, result, messages|
      s = server(protocols: %w[h2]) { |r| r.path == path ? json(status, { "statusCode" => "x" }, headers) : json(500, {}) }
      outcome = run_check(criterion["check"], s.url("/dpp/v1"), features: %w[fine-granular-api access-levels],
                                                                 test_data: { "controlledElementIdPath" => "$.#{FakeDppService::CONTROLLED}" })
      assert_equal result, outcome.result, "#{status} #{headers.inspect}: #{messages_text(outcome).inspect}"
      assert_equal messages, messages_text(outcome), "#{status} #{headers.inspect}"
      assert_equal [path], s.received.map(&:path)
    end
  end

  test "self-declarations of the entry are listed with statement and evidence, apart from the results and never counted" do
    repository = DppValidator::CriteriaRepository.new(CRITERIA_DIR)
    declarations = [
      { "criterion" => "DPP-ACC-015", "statement" => "  Every actor is identified by a DID.\n", "evidence" => "https://example.org/doc#auth" },
      { "criterion" => "DPP-XYZ-999", "statement" => "Not a criterion of the checkout.", "evidence" => "https://example.org/other" }
    ]
    plain = run_with(repository)
    report = run_with(repository, service(declarations: declarations))

    listed = report.to_h["declarations"]
    assert_equal DppValidator::Report::DECLARATIONS_NOTICE, listed["notice"]
    first, second = listed["items"]
    acc015 = repository.criteria.find { |c| c.id == "DPP-ACC-015" }
    assert_equal %w[DPP-ACC-015 Every\ actor\ is\ identified\ by\ a\ DID. https://example.org/doc#auth],
                 first.values_at("criterion", "statement", "evidence")
    assert_equal [acc015["title"], acc015["status"]], first.values_at("title", "status")
    url = repository.description_url("DPP-ACC-015")
    url ? assert_equal(url, first["description_url"]) : refute(first.key?("description_url"))
    assert_equal({ "criterion" => "DPP-XYZ-999", "statement" => "Not a criterion of the checkout.", "evidence" => "https://example.org/other" },
                 second)

    by_id = results(report)
    assert_equal %w[skipped not_evaluated], by_id["DPP-ACC-015"].values_at("result", "reason_code")
    assert_match(/declaration of the operator is listed under self-declarations; declarations are not evaluated and never count as passed/,
                 by_id["DPP-ACC-015"]["reason"])
    assert_match(/the entry has no declaration for it; declarations are not evaluated/, by_id["DPP-ACC-014"]["reason"])
    refute by_id["DPP-ACC-015"]["counted"]
    assert_equal plain.summary, report.summary
    assert_equal plain.proposed_summary, report.proposed_summary
    assert_equal plain.results.map { |r| r.except("reason", "details") }, report.results.map { |r| r.except("reason", "details") }

    refute plain.to_h.key?("declarations")
    text = report.to_text
    assert_includes text, "self-declarations of the operator (listed, not checked, not counted): 2"
    assert_includes text, "DPP-ACC-015  https://example.org/doc#auth"
    refute_includes plain.to_text, "self-declarations of the operator"
  end
end
