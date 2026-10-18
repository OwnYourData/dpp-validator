require_relative "test_helper"

class LinterTest < ValidatorTestCase
  PASSPORT = "https://dpp.example/01/09520123456788/21/000001".freeze

  def dpplint_answer
    { "productId" => PASSPORT, "dpp-criteria" => "c685613",
      "summary" => { "text" => "5 of 5 automated checks passed", "passed" => 5, "failed" => 0, "warnings" => 1, "skipped" => 1,
                     "proposed_not_counted" => { "text" => "9 of 10 automated checks passed", "passed" => 9, "failed" => 1 } },
      "criteria" => [{ "id" => "DPP-ID-016", "title" => "DID", "status" => "active", "result" => "warning", "messages" => [{}] },
                     { "id" => "DPP-SEC-002", "title" => "Proof", "status" => "active", "result" => "skipped", "reason_code" => "no_evidence" }] }
  end

  def entry(passports)
    DppValidator::Service.new("id" => "svc", "name" => "Service", "example_passports" => passports)
  end

  test "checks every example passport through the dpplint API and keeps its counting" do
    dpplint = server { |_req| json(200, dpplint_answer) }
    linter = DppValidator::Linter.new(base_url: dpplint.url("/"), config: config(read_timeout: 5), now: NOW)
    result = linter.run(entry([{ "product_id" => PASSPORT, "label" => "reference passport" }]))
    request = dpplint.received.first
    assert_equal "/api/v1/validate/#{PASSPORT}", request.path
    assert_equal DppValidator::USER_AGENT, request.headers["user-agent"].then { |v| v.is_a?(Array) ? v.first : v }
    assert_includes DppValidator::USER_AGENT, "office@ownyourdata.eu"
    assert_equal "svc", result["service_id"]
    assert_equal "2026-09-28T12:00:00Z", result["checked_at"]
    p = result["passports"].first
    assert_equal "checked", p["status"]
    assert_equal "#{dpplint.url}/?productId=#{CGI.escape(PASSPORT)}", p["lint_url"]
    assert_equal({ "text" => "5 of 5 automated checks passed", "passed" => 5, "failed" => 0, "total" => 5, "warnings" => 1,
                   "skipped" => 1, "proposed_failed" => 1 }, p["summary"])
    assert_equal %w[id title status result], p["criteria"].first.keys
    assert_equal "no_evidence", p["criteria"].last["reason_code"]
  end

  test "an error of dpplint is reported per passport" do
    dpplint = server { |req| req.path.include?("broken") ? [502, {}, "bad gateway"] : json(200, "not json at all") }
    linter = DppValidator::Linter.new(base_url: dpplint.url, config: config(read_timeout: 5), now: NOW)
    result = linter.run(entry([{ "product_id" => "https://dpp.example/broken", "label" => "a" },
                               { "product_id" => "https://dpp.example/other", "label" => "b" }]))
    first, second = result["passports"]
    assert_equal "error", first["status"]
    assert_match(/dpplint: HTTP 502/, first["error"])
    assert_equal "error", second["status"]
    assert_match(/invalid JSON/, second["error"])
  end
end
