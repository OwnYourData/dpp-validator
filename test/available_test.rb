require_relative "test_helper"

class AvailableTest < ValidatorTestCase
  def service(id, name, source:, check:, passports: [], **extra)
    DppValidator::Service.new({ "id" => id, "name" => name, "url" => "https://#{id}.example/",
                                "operator" => { "name" => "#{name} Ltd", "country" => "AT" },
                                "entry" => { "source" => source, "as_of" => "2026-10-18" },
                                "licence" => { "text" => "MIT", "spdx" => ["MIT"] }, "check" => check,
                                "example_passports" => passports }.merge(extra))
  end

  def build
    services = [
      service("zz-research", "Alpha research", source: "research", check: { "mode" => "read-only-weekly" }),
      service("none", "Beta", source: "research", check: { "mode" => "none", "reason" => "needs_credentials" },
              passports: [{ "product_id" => "https://none.example/01/1", "label" => "demo" }]),
      service("ours", "Our service", source: "operator", check: { "mode" => "full-daily" },
              passports: [{ "product_id" => "https://ours.example/01/1", "label" => "reference passport" }])
    ]
    results = { "ours" => { "run_at" => "2026-10-18T04:17:00Z", "mode" => "full",
                            "summary" => { "text" => "14 of 15 automated checks passed", "passed" => 14, "failed" => 1, "warnings" => 2,
                                           "proposed_not_counted" => { "failed" => 3 } } } }
    lints = { "ours" => { "checked_at" => "2026-10-18T04:20:00Z", "dpplint" => "https://dpplint.example",
                          "passports" => [{ "product_id" => "https://ours.example/01/1", "status" => "checked",
                                            "lint_url" => "https://dpplint.example/?productId=x",
                                            "summary" => { "text" => "5 of 5 automated checks passed", "passed" => 5, "failed" => 0,
                                                           "total" => 5, "warnings" => 1 } }] },
              "none" => { "checked_at" => "2026-10-12T05:00:00Z",
                          "passports" => [{ "product_id" => "https://none.example/01/1", "status" => "error", "error" => "dpplint: HTTP 502" }] } }
    DppValidator::Available.new(services: services, results: results, lints: lints, site_url: "https://pages.example/v",
                                this_service: "ours", now: NOW).to_h
  end

  test "lists every entry in the format of the start page, this service first, then operator and research entries" do
    data = build
    assert_equal %w[generated_at notice counting services], data.keys
    assert_equal "2026-09-28T12:00:00Z", data["generated_at"]
    assert_match(/research project/, data["notice"])
    assert_match(/no certification/, data["notice"])
    assert_equal %w[ours zz-research none], data["services"].map { |s| s["id"] }, "this service, then research entries by name"
    ours = data["services"].first
    assert_equal %w[id name url provider this_service entry licence linter validator], ours.keys
    assert ours["this_service"]
    assert_equal({ "name" => "Our service Ltd", "country" => "AT" }, ours["provider"])
    assert_equal({ "source" => "operator", "as_of" => "2026-10-18" }, ours["entry"])
    assert_equal({ "text" => "MIT", "spdx" => ["MIT"] }, ours["licence"])
  end

  test "linter and validator count warnings as passed and total as passed plus failed" do
    ours = build["services"].first
    p = ours["linter"]["passports"].first
    assert_equal({ "product_id" => "https://ours.example/01/1", "label" => "reference passport",
                   "lint_url" => "https://dpplint.example/?productId=#{CGI.escape('https://ours.example/01/1')}",
                   "summary_text" => "5 of 5 automated checks passed", "passed" => 5, "total" => 5, "failed" => 0, "warnings" => 1,
                   "checked_at" => "2026-10-18", "note" => nil }, p)
    assert_equal({ "status" => "checked", "mode" => "full", "cadence" => "daily",
                   "details_url" => "https://pages.example/v/services/ours.html",
                   "summary_text" => "14 of 15 automated checks passed", "passed" => 14, "total" => 15, "failed" => 1,
                   "warnings" => 2, "proposed_failed" => 3, "checked_at" => "2026-10-18" }, ours["validator"])
  end

  test "entries without results, without public passports or not checked say why" do
    by_id = build["services"].to_h { |s| [s["id"], s] }
    assert_equal({ "status" => "pending", "mode" => "read-only", "cadence" => "weekly",
                   "details_url" => "https://pages.example/v/services/zz-research.html" }, by_id["zz-research"]["validator"])
    assert_equal({ "passports" => [], "note" => "no public example passport" }, by_id["zz-research"]["linter"])
    refute by_id["zz-research"]["this_service"]
    assert_equal({ "status" => "needs_credentials" }, by_id["none"]["validator"])
    p = by_id["none"]["linter"]["passports"].first
    assert_nil p["summary_text"]
    assert_equal "dpplint: HTTP 502", p["note"]
    assert_equal "2026-10-12", p["checked_at"]
  end
end
