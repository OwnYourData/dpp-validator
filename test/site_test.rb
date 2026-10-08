require_relative "test_helper"
require "tmpdir"

class SiteTest < ValidatorTestCase
  def result(id, name, criteria)
    {
      "notice" => DppValidator::Report::NOTICE,
      "service" => { "id" => id, "name" => name, "operator" => "Op <&>", "operator_url" => "https://op.example",
                     "contact" => "office@op.example", "api_base" => "https://api.example/v1", "listed_since" => "2026-10-08" },
      "run_at" => "2026-10-08T12:00:00Z",
      "dpp_criteria" => { "commit" => "c5a0a5ce389ac662ae7612a1bc50d520c09991d9" },
      "summary" => { "text" => "1 of 2 automated checks passed", "passed" => 1, "failed" => 1, "warnings" => 0, "skipped" => 0,
                     "proposed_not_counted" => { "text" => "0 of 0 automated checks passed" } },
      "criteria" => criteria
    }
  end

  def criterion(id, status, result, **extra)
    { "id" => id, "version" => 1, "status" => status, "title" => "Title of #{id}", "level" => "MUST", "result" => result,
      "messages" => [], "counted" => status == "active" && result != "skipped" }.merge(extra.transform_keys(&:to_s))
  end

  test "writes index.html with one section per service and copies the JSON results" do
    Dir.mktmpdir do |dir|
      results = File.join(dir, "in")
      FileUtils.mkdir_p(results)
      File.write(File.join(results, "a.json"), JSON.generate(result("svc-a", "Service <A>", [
        criterion("DPP-DEX-006", "active", "failed", messages: [{ "severity" => "error", "message" => "HTTP/1.1 not rejected" }]),
        criterion("DPP-API-013", "active", "passed"),
        criterion("DPP-OPS-006", "proposed", "skipped", reason: "self-declared")
      ])))
      File.write(File.join(results, "b.json"), JSON.generate(result("svc-b", "Service B", [criterion("DPP-API-013", "active", "passed")])))
      out = File.join(dir, "site")
      assert_equal 2, DppValidator::Site.new(results_dir: results, output_dir: out).build
      html = File.read(File.join(out, "index.html"))
      assert_includes html, %(<section id="svc-a">)
      assert_includes html, %(<section id="svc-b">)
      assert_includes html, "Service &lt;A&gt;"
      assert_includes html, "Op &lt;&amp;&gt;"
      assert_includes html, "1 of 2 automated checks passed"
      assert_includes html, "Proposed criteria, not counted: 0 of 0 automated checks passed"
      assert_includes html, "(proposed, not counted)"
      assert_includes html, "error: HTTP/1.1 not rejected"
      assert_includes html, "mailto:office@op.example"
      assert_includes html, "dpp-criteria/blob/c5a0a5ce389ac662ae7612a1bc50d520c09991d9/criteria/dex/DPP-DEX-006.yaml"
      assert_includes html, DppValidator::Report::NOTICE
      refute_match(/conformant|certified/i, html.sub(DppValidator::Report::NOTICE, ""))
      refute_match(%r{<(script|link)\b|src="http}i, html, "no external resources")
      assert html.index("DPP-DEX-006") < html.index("DPP-API-013"), "failed before passed"
      assert html.index("DPP-API-013") < html.index("DPP-OPS-006"), "proposed after active"
      assert_equal "svc-a", JSON.parse(File.read(File.join(out, "results", "svc-a.json"))).dig("service", "id")
    end
  end

  test "no results is a configuration error" do
    Dir.mktmpdir do |dir|
      assert_raises(DppValidator::Error) { DppValidator::Site.new(results_dir: dir, output_dir: File.join(dir, "o")).build }
    end
  end
end
