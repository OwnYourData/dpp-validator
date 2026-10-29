require_relative "test_helper"
require "tmpdir"

class SiteTest < ValidatorTestCase
  def result(id, name, criteria, mode: "full")
    {
      "notice" => DppValidator::Report::NOTICE,
      "service" => { "id" => id, "name" => name, "operator" => "Op <&>", "operator_url" => "https://op.example",
                     "contact" => "office@op.example", "api_base" => "https://api.example/v1", "listed_since" => "2026-10-08" },
      "run_at" => "2026-10-08T12:00:00Z",
      "mode" => mode,
      "dpp_criteria" => { "commit" => "c5a0a5ce389ac662ae7612a1bc50d520c09991d9" },
      "summary" => { "text" => "1 of 2 automated checks passed", "passed" => 1, "failed" => 1, "warnings" => 0, "skipped" => 1,
                     "skipped_by_reason" => { "not_implemented" => 1 },
                     "proposed_not_counted" => { "text" => "0 of 0 automated checks passed", "failed" => 0 } },
      "criteria" => criteria
    }
  end

  def criterion(id, status, result, **extra)
    { "id" => id, "version" => 1, "status" => status, "title" => "Title of #{id}", "level" => "MUST", "result" => result,
      "messages" => [], "counted" => status == "active" && result != "skipped" }.merge(extra.transform_keys(&:to_s))
  end

  def entry(id, name, source: "operator", check: { "mode" => "full-daily" }, **extra)
    data = { "id" => id, "name" => name, "operator" => { "name" => "Op <&>", "url" => "https://op.example", "country" => "AT" },
             "entry" => { "source" => source, "as_of" => "2026-10-18" }, "licence" => { "text" => "MIT", "spdx" => ["MIT"] },
             "check" => check, "listed_since" => "2026-10-08" }
    data.merge!("contact" => "office@op.example", "api_base" => "https://api.example/v1") if source == "operator"
    DppValidator::Service.new(data.merge(extra.transform_keys(&:to_s)))
  end

  def lint(id, product_id)
    { "service_id" => id, "checked_at" => "2026-10-18T04:20:00Z", "dpplint" => "https://dpplint.example",
      "passports" => [{ "product_id" => product_id, "label" => "demo passport", "lint_url" => "https://dpplint.example/?productId=x",
                        "status" => "checked", "dpp_criteria" => "c685613",
                        "summary" => { "text" => "3 of 4 automated checks passed", "passed" => 3, "failed" => 1, "total" => 4,
                                       "warnings" => 1, "skipped" => 2, "proposed_failed" => 0 },
                        "criteria" => [{ "id" => "DPP-ID-001", "title" => "Resolves", "status" => "active", "result" => "failed" },
                                       { "id" => "DPP-DAT-016", "title" => "HTML", "status" => "active", "result" => "warning" },
                                       { "id" => "DPP-CAR-002", "title" => "Scheme", "status" => "proposed", "result" => "warning" },
                                       { "id" => "DPP-ID-002", "title" => "Stays resolvable", "status" => "proposed", "result" => "warning",
                                         "message" => "DPP-ID-001 failed in 1 of 3 runs from 2026-10-16 to 2026-10-18: 2026-10-18",
                                         "history" => { "criterion" => "DPP-ID-001", "period_days" => 30, "runs" => 3, "failed" => 1 } }] }] }
  end

  def build(dir, services:, results: {}, lints: {}, **options)
    input = File.join(dir, "in")
    FileUtils.mkdir_p(File.join(input, "linter"))
    results.each { |id, r| File.write(File.join(input, "#{id}.json"), JSON.generate(r)) }
    lints.each { |id, l| File.write(File.join(input, "linter", "#{id}.json"), JSON.generate(l)) }
    out = File.join(dir, "site")
    count = DppValidator::Site.new(results_dir: input, output_dir: out, services: services, now: NOW, **options).build
    [count, out]
  end

  def assert_page_rules(html, up = "")
    refute_match(/conformant|certified/i, html.sub(DppValidator::Report::NOTICE, ""))
    header = html[%r{<header>.*</header>}m]
    assert header, "header"
    assert html.index("</header>") < html.index("<main"), "header outside main, so its line spans the window"
    assert_includes header, %(<a class="brand" href="#{up}index.html"><img class="mark" src="#{up}oyd-mark.svg" alt="" width="15" height="28">DPP Service Validator <span>&middot; OwnYourData</span></a>)
    assert_includes header, %(<a href="https://dpp-service.ownyourdata.eu/">DPP Service</a>)
    assert_includes header, %(<a href="https://github.com/OwnYourData/dpp-validator">GitHub</a>)
    refute_match(%r{<script\b|src="(https?:)?//}i, html, "no external resources")
    html.scan(/<link\b[^>]*>/i).each { |link| refute_match(%r{href="(https?:)?//}i, link, "no external resources") }
    footer = html[%r{<footer>.*</footer>}m]
    assert footer, "footer"
    assert html.index("</main>") < html.index("<footer>"), "footer outside main, so its line spans the window"
    refute_match(/body \{[^}]*max-width/, html, "body is not limited in width")
    assert_includes footer, %(Operated by <a href="https://www.ownyourdata.eu/en/">OwnYourData</a>)
    assert_includes footer, %(<a href="https://www.ownyourdata.eu/en/imprint/">Imprint</a>)
    assert_includes footer, %(<a href="https://www.ownyourdata.eu/en/privacy-policy/">Privacy</a>)
    assert_includes footer, %(<div class="funding">#{DppValidator::Funding.html}</div>)
    assert_equal 1, html.scan("917177").size
  end

  test "writes an overview, one detail page per entry and the JSON results" do
    Dir.mktmpdir do |dir|
      services = [
        entry("svc-a", "Service <A>"),
        entry("svc-b", "Service B", source: "research", check: { "mode" => "read-only-weekly" }, "api_base" => "https://b.example/v1",
              "example_passports" => [{ "product_id" => "https://b.example/01/1", "label" => "demo passport" }], "notes" => "Demo <only>."),
        entry("svc-c", "Service C", source: "research", check: { "mode" => "none", "reason" => "no_public_instance" })
      ]
      results = {
        "svc-a" => result("svc-a", "Service <A>", [
          criterion("DPP-DEX-006", "active", "failed", messages: [{ "severity" => "error", "message" => "HTTP/1.1 not rejected" }]),
          criterion("DPP-API-013", "active", "passed",
                    description_url: "https://github.com/OwnYourData/dpp-criteria/blob/c5a0a5c/criteria/README.md#dpp-api-013"),
          criterion("DPP-OPS-006", "proposed", "skipped", reason: "self-declared", reason_code: "not_evaluated"),
          criterion("DPP-API-019", "active", "skipped", reason: "the service lists historical-versions as not implemented",
                    reason_code: "not_implemented")
        ]),
        "gone" => result("gone", "No longer listed", [])
      }
      count, out = build(dir, services: services, results: results, lints: { "svc-b" => lint("svc-b", "https://b.example/01/1") },
                              this_service: "svc-a")
      assert_equal 3, count

      index = File.read(File.join(out, "index.html"), encoding: "UTF-8")
      assert_page_rules(index)
      assert_includes index, %(<a href="services/svc-a.html">Service &lt;A&gt;</a><br>)
      assert_includes index, "Entry maintained by the operator"
      assert_includes index, "Entry from our research · as of 2026-10-18"
      assert_includes index, "1 of 2 passed · full, daily"
      assert_includes index, "first run pending · read-only, weekly"
      assert_includes index, "not checked: no public instance"
      assert_includes index, %(<a href="https://dpplint.example/?productId=x">demo passport</a>: 3 of 4 passed · 1 warning)
      assert_includes index, "no public example passport"
      assert_includes index, DppValidator::Site::RESEARCH_NOTICE
      assert_includes index, %(<a href="available-services.json">available-services.json</a>)
      refute_includes index, "No longer listed"
      assert index.index("svc-a.html") < index.index("svc-b.html"), "this service first"
      assert_includes index, %(<link rel="icon" href="oyd-mark.svg" type="image/svg+xml">)
      about = index[index.index(%(<h2 id="about">About these checks</h2>))..]
      assert index.index("</table>") < index.index(%(<h2 id="about">)), "about after the table"
      assert_includes index, %(<a href="#about">About these checks</a>)
      [DppValidator::Site::OTHERS_NOTICE, DppValidator::Site::NO_SEAL_NOTICE, DppValidator::Site::OWN_ROLE_NOTICE,
       DppValidator::Site::REQUESTS_NOTICE].each { |text| assert_includes about, text }
      assert_includes about, "without the consent of their operators"
      assert_includes about, %(<a href="mailto:office@ownyourdata.eu">office@ownyourdata.eu</a>)
      assert_includes about, %(<a href="https://github.com/OwnYourData/dpp-criteria/issues">issue in dpp-criteria</a>)
      assert_includes about, %(<a href="https://github.com/OwnYourData/dpp-validator#listing-correction-and-removal">how we handle requests</a>)

      a = File.read(File.join(out, "services", "svc-a.html"), encoding: "UTF-8")
      assert_page_rules(a, "../")
      assert_includes a, "Op &lt;&amp;&gt; · AT"
      assert_includes a, "1 of 2 automated checks passed"
      assert_includes a, "Proposed criteria, not counted: 0 of 0 automated checks passed"
      assert_includes a, "(proposed, not counted)"
      assert_includes a, "error: HTTP/1.1 not rejected"
      assert_includes a, "1 skipped: 1 not implemented"
      assert_includes a, %(<span class="muted">not evaluated</span>)
      assert_includes a, "mailto:office@op.example"
      assert_includes a, "dpp-criteria/blob/c5a0a5ce389ac662ae7612a1bc50d520c09991d9/criteria/dex/DPP-DEX-006.yaml"
      assert_includes a, %(href="https://github.com/OwnYourData/dpp-criteria/blob/c5a0a5c/criteria/README.md#dpp-api-013")
      assert_includes a, %(<a href="../results/svc-a.json">JSON</a>)
      assert_includes a, %(<link rel="icon" href="../oyd-mark.svg" type="image/svg+xml">)
      assert_includes a, DppValidator::Report::NOTICE
      refute_includes a, DppValidator::Site::RESEARCH_NOTICE
      assert_includes a, DppValidator::Site::DETAIL_DISCLOSURE
      assert_includes a, %(<a href="mailto:office@ownyourdata.eu">office@ownyourdata.eu</a>)
      assert_includes a, %(<a href="../index.html#about">about these checks</a>)
      assert a.index("DPP-DEX-006") < a.index("DPP-API-013"), "failed before passed"
      assert a.index("DPP-API-013") < a.index("DPP-OPS-006"), "proposed after active"
      refute_includes a, "Self-declarations of the operator"
      refute_includes index, "self-declaration"

      b = File.read(File.join(out, "services", "svc-b.html"), encoding: "UTF-8")
      assert_page_rules(b, "../")
      assert_includes b, "<strong>Entry from our research</strong> &middot; information as of 2026-10-18"
      assert_includes b, "Demo &lt;only&gt;."
      assert_includes b, DppValidator::Site::RESEARCH_NOTICE
      assert_includes b, DppValidator::Site::DETAIL_DISCLOSURE
      assert_includes b, "3 of 4 automated checks passed"
      assert b.index("DPP-ID-001") < b.index("DPP-DAT-016"), "failed before warning"
      assert_includes b, "Stays resolvable <span class=\"muted\">(proposed, not counted)</span>" \
                         "<ul class=\"msg\"><li>rated by dpp-validator from its stored runs: DPP-ID-001 failed in 1 of 3 runs " \
                         "from 2026-10-16 to 2026-10-18: 2026-10-18</li></ul>"
      assert b.index("DPP-DAT-016") < b.index("DPP-ID-002"), "proposed after active"
      refute_includes b, "DPP-CAR-002", "proposed criteria from dpplint are counted in the summary only"
      assert_includes b, "First run pending · read-only, weekly."

      c = File.read(File.join(out, "services", "svc-c.html"), encoding: "UTF-8")
      assert_includes c, "Not checked: no public instance."

      assert_equal "svc-a", JSON.parse(File.read(File.join(out, "results", "svc-a.json"), encoding: "UTF-8")).dig("service", "id")
      refute File.exist?(File.join(out, "results", "gone.json"))
      assert_equal "svc-b", JSON.parse(File.read(File.join(out, "linter", "svc-b.json"), encoding: "UTF-8"))["service_id"]
      assert_equal File.binread(DppValidator::Site::MARK), File.binread(File.join(out, "oyd-mark.svg"))
      available = JSON.parse(File.read(File.join(out, "available-services.json"), encoding: "UTF-8"))
      assert_equal %w[svc-a svc-b svc-c], available["services"].map { |s| s["id"] }
    end
  end

  test "self-declarations get a section of their own after the checks, without result, and are not counted" do
    Dir.mktmpdir do |dir|
      r = result("svc-a", "Service A", [
        criterion("DPP-API-013", "active", "passed"),
        criterion("DPP-ACC-015", "proposed", "skipped", method: "self-declared", reason_code: "not_evaluated",
                  reason: "self-declared criterion: the declaration of the operator is listed under self-declarations")
      ])
      r["declarations"] = {
        "notice" => DppValidator::Report::DECLARATIONS_NOTICE,
        "items" => [
          { "criterion" => "DPP-ACC-015", "title" => "Actors are identified", "status" => "proposed",
            "description_url" => "https://github.com/OwnYourData/dpp-criteria/blob/c5a0a5c/criteria/README.md#dpp-acc-015",
            "statement" => "Every <actor> presents a DID & a token.", "evidence" => "https://example.org/doc?a=1&b=2#auth" },
          { "criterion" => "DPP-XYZ-999", "statement" => "Unknown criterion.", "evidence" => "https://example.org/other" }
        ]
      }
      _, out = build(dir, services: [entry("svc-a", "Service A")], results: { "svc-a" => r })
      a = File.read(File.join(out, "services", "svc-a.html"), encoding: "UTF-8")
      assert_page_rules(a, "../")
      assert_includes a, %(<h2 id="self-declarations">Self-declarations of the operator</h2>)
      assert_includes a, DppValidator::Report::DECLARATIONS_NOTICE
      assert_includes a, %(<div class="decl" id="declaration-dpp-acc-015">)
      assert_includes a, %(href="https://github.com/OwnYourData/dpp-criteria/blob/c5a0a5c/criteria/README.md#dpp-acc-015")
      assert_includes a, "Actors are identified <span class=\"muted\">(criterion proposed)</span>"
      assert_includes a, "<p>Every &lt;actor&gt; presents a DID &amp; a token.</p>"
      assert_includes a, %(Evidence: <a href="https://example.org/doc?a=1&amp;b=2#auth">https://example.org/doc?a=1&amp;b=2#auth</a>)
      assert_includes a, "dpp-criteria/blob/c5a0a5ce389ac662ae7612a1bc50d520c09991d9/criteria/xyz/DPP-XYZ-999.yaml"
      assert_includes a, %(<li><a href="#declaration-dpp-acc-015">Self-declaration of the operator</a></li>)
      index = File.read(File.join(out, "index.html"), encoding: "UTF-8")
      assert_includes index, %(<br><a class="muted" href="services/svc-a.html#self-declarations">2 self-declarations, not counted</a>)
      available = JSON.parse(File.read(File.join(out, "available-services.json"), encoding: "UTF-8"))
      assert_equal 2, available["services"].first["validator"]["self_declarations"]
      assert_equal 1, a.scan("#declaration-").size, "only the self-declared criterion links to its declaration"
      section = a[a.index(%(<h2 id="self-declarations">))..]
      assert a.rindex("</table>") < a.index(%(<h2 id="self-declarations">)), "after the table of the checks"
      refute_includes section[0, section.index(%(<p class="notice">#{DppValidator::Report::NOTICE}))], "badge"
      assert_includes a, "1 of 2 automated checks passed"
    end
  end

  test "without entries the site is built from the validator results" do
    Dir.mktmpdir do |dir|
      count, out = build(dir, services: nil, results: { "svc-a" => result("svc-a", "Service A", [criterion("DPP-API-013", "active", "passed")]) })
      assert_equal 1, count
      assert_includes File.read(File.join(out, "index.html"), encoding: "UTF-8"), "Service A"
    end
  end

  test "no entries and no results is a configuration error" do
    Dir.mktmpdir do |dir|
      assert_raises(DppValidator::Error) { DppValidator::Site.new(results_dir: dir, output_dir: File.join(dir, "o")).build }
    end
  end
end
