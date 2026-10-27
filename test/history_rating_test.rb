require_relative "test_helper"
require "tmpdir"

class HistoryRatingTest < DpplintTestCase
  TODAY = Date.new(2026, 10, 26)
  PRODUCT_ID = "https://dpp.example.org/01/04012345000016/21/0001".freeze

  def criterion(status: "proposed", period: 30, needed: 3, errors: [])
    data = { "id" => "DPP-ID-002", "status" => status, "target" => "passport",
             "check" => { "type" => "resolve",
                          "history" => { "criterion" => "DPP-ID-001", "period_days" => period, "fail_after_consecutive_runs" => needed } } }
    DppValidator::CriteriaRepository::Criterion.new(data: data, file: "criteria/id/DPP-ID-002.yaml", schema_errors: errors)
  end

  def entry(id, status, result, **extra)
    { "id" => id, "title" => "Title of #{id}", "status" => status, "result" => result,
      "description_url" => "https://example.org/#{id.downcase}" }.merge(extra.transform_keys(&:to_s))
  end

  # A passport as Linter#check writes it; id001: result of DPP-ID-001 (nil: not listed).
  def passport(id001, id002_status: "proposed", product_id: PRODUCT_ID)
    criteria = [entry("DPP-DAT-016", "active", "passed")]
    criteria << entry("DPP-ID-001", "active", id001) if id001
    criteria << entry("DPP-ID-002", id002_status, "skipped", reason_code: "not_evaluated")
    { "product_id" => product_id, "label" => "reference passport", "status" => "checked", "dpp_criteria" => "abc1234",
      "summary" => DppValidator::Linter.summary_of(criteria), "criteria" => criteria }
  end

  def lint(passports) = { "service_id" => "svc", "checked_at" => "#{TODAY}T04:20:00Z", "passports" => passports }

  # results: { days_ago => DPP-ID-001 result | :error | :absent }
  def with_runs(results)
    Dir.mktmpdir do |dir|
      results.each do |days_ago, result|
        next if result == :absent

        path = File.join(dir, (TODAY - days_ago).iso8601, "linter", "svc.json")
        FileUtils.mkdir_p(File.dirname(path))
        p = result == :error ? { "product_id" => PRODUCT_ID, "status" => "error", "error" => "dpplint: timeout" } : passport(result)
        File.write(path, JSON.generate(lint([p])))
      end
      yield dir
    end
  end

  def rate(dir, today_result, **options)
    rating = DppValidator::HistoryRating.new(criteria: [criterion(**options)], runs_dir: dir, today: TODAY)
    rating.apply(lint([passport(today_result, id002_status: options.fetch(:status, "proposed"))]))["passports"].first
  end

  def id002(passport) = passport["criteria"].find { |c| c["id"] == "DPP-ID-002" }

  test "passed if DPP-ID-001 passed in every run of the period, with the runs named" do
    with_runs(4 => "passed", 3 => "warning", 1 => "passed") do |dir|
      c = id002(rate(dir, "passed"))
      assert_equal "passed", c["result"]
      assert_equal "DPP-ID-001 passed in all 4 runs from 2026-10-22 to 2026-10-26", c["message"]
      assert_equal({ "criterion" => "DPP-ID-001", "period_days" => 30, "runs" => 4, "failed" => 0,
                     "from" => "2026-10-22", "to" => "2026-10-26" }, c["history"])
      assert_equal %w[id title status description_url result history message].sort, c.keys.sort
    end
  end

  test "failures in single runs give a warning that names them" do
    with_runs(5 => "passed", 4 => "failed", 3 => "passed", 2 => "failed", 1 => "failed") do |dir|
      c = id002(rate(dir, "passed"))
      assert_equal "warning", c["result"]
      assert_equal "DPP-ID-001 failed in 3 of 6 runs from 2026-10-21 to 2026-10-26: 2026-10-22, 2026-10-24, 2026-10-25", c["message"]
    end
  end

  test "failed after as many consecutive failed runs as the criterion names; runs without a result are left out" do
    with_runs(9 => "passed", 8 => "failed", 7 => "skipped", 6 => :error, 5 => :absent, 4 => "failed", 2 => "passed") do |dir|
      c = id002(rate(dir, "failed"))
      assert_equal "warning", c["result"], "2026-10-24 passed and ends the sequence"
    end
    with_runs(9 => "passed", 8 => "failed", 7 => "skipped", 6 => :error, 4 => "failed") do |dir|
      c = id002(rate(dir, "failed"))
      assert_equal "failed", c["result"]
      assert_equal "DPP-ID-001 failed in 3 consecutive runs: 2026-10-18, 2026-10-22, 2026-10-26", c["message"]
      assert_equal 4, c.dig("history", "runs")
    end
  end

  test "a failure that has left the period no longer counts" do
    with_runs(31 => "failed", 30 => "failed", 29 => "failed", 2 => "passed", 1 => "passed") do |dir|
      c = id002(rate(dir, "passed"))
      assert_equal "warning", c["result"]
      assert_equal "DPP-ID-001 failed in 1 of 4 runs from 2026-09-27 to 2026-10-26: 2026-09-27", c["message"]
    end
  end

  test "earlier runs of the same day are replaced by today's result" do
    with_runs(0 => "failed", 2 => "passed", 1 => "passed") do |dir|
      c = id002(rate(dir, "passed"))
      assert_equal "passed", c["result"]
      assert_equal 3, c.dig("history", "runs")
    end
  end

  test "with fewer runs than needed the criterion is not rated" do
    with_runs(1 => "passed") do |dir|
      c = id002(rate(dir, "passed"))
      assert_equal "skipped", c["result"]
      assert_equal "not_evaluated", c["reason_code"]
      assert_equal "DPP-ID-001 has a result in only 2 runs of the last 30 days; the rating needs at least 3 runs", c["message"]
    end
    with_runs({}) do |dir|
      assert_equal "DPP-ID-001 has no result in the runs of the last 30 days; the rating needs at least 3 runs",
                   id002(rate(dir, "skipped"))["message"]
    end
  end

  test "the summary is counted again: a proposed failure in proposed_failed, an active one in N of M" do
    with_runs(2 => "failed", 1 => "failed") do |dir|
      proposed = rate(dir, "failed")
      assert_equal "failed", id002(proposed)["result"]
      assert_equal "1 of 2 automated checks passed", proposed.dig("summary", "text")
      assert_equal 1, proposed.dig("summary", "proposed_failed")

      active = rate(dir, "failed", status: "active")
      assert_equal "failed", id002(active)["result"]
      assert_equal({ "text" => "1 of 3 automated checks passed", "passed" => 1, "failed" => 2, "total" => 3, "warnings" => 0,
                     "skipped" => 0, "proposed_failed" => 0 }, active["summary"])
    end
  end

  test "passports with an error, without the criterion or with another product identifier stay as they are" do
    with_runs(2 => "passed", 1 => "passed") do |dir|
      rating = DppValidator::HistoryRating.new(criteria: [criterion], runs_dir: dir, today: TODAY)
      error = { "product_id" => PRODUCT_ID, "status" => "error", "error" => "dpplint: timeout" }
      without = passport("passed").tap { |p| p["criteria"].reject! { |c| c["id"] == "DPP-ID-002" } }
      other = passport("passed", product_id: "https://dpp.example.org/01/04012345000016/21/0002")
      rated = rating.apply(lint([error, without, other]))["passports"]
      assert_equal error, rated[0]
      assert_equal without, rated[1]
      assert_equal "DPP-ID-001 has a result in only 1 run of the last 30 days; the rating needs at least 3 runs", id002(rated[2])["message"]
    end
  end

  test "criteria without history or with schema errors are not rated" do
    with_runs(2 => "passed", 1 => "passed") do |dir|
      broken = DppValidator::HistoryRating.new(criteria: [criterion(errors: ["bad"])], runs_dir: dir, today: TODAY)
      refute broken.any?
      incomplete = criterion.tap { |c| c.data["check"]["history"].delete("criterion") }
      refute DppValidator::HistoryRating.new(criteria: [incomplete], runs_dir: dir, today: TODAY).any?
      result = lint([passport("passed")])
      assert_equal result, broken.apply(result)
    end
  end
end
