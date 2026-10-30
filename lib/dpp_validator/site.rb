require "cgi"
require "fileutils"

module DppValidator
  # Static result pages for GitHub Pages:
  #
  # - index.html: overview of every entry of services/ with its latest
  #   results (dpplint for the example passports, dpp-validator for the
  #   service, with the number of self-declarations);
  # - services/<id>.html: one page per entry with the details of the entry,
  #   the criteria of the latest validator run, the self-declarations of the
  #   operator in a section of their own (not checked, never counted) and the
  #   dpplint results of its example passports;
  # - results/<id>.json and linter/<id>.json: the JSON results;
  # - available-services.json (Available).
  #
  # The header names the DPP Service Validator next to the mark (assets/oyd-mark.svg,
  # also the icon, copied next to index.html) and links to the DPP Service and
  # to this repository, as on the start page of the DPP Service. Header and
  # footer span the full width of the window
  # and names the operator and the imprint of OwnYourData, the privacy policy of
  # the DPP services (on the DPP Service)
  # and the funding notice of config/funding.yml; only its content and the main
  # content are limited to the width of the page (.wrap).
  #
  # Wording follows CRITERIA-FORMAT.md ("Results wording"): "N of M automated
  # checks passed" for active criteria only, proposed criteria marked as not
  # counted, entries from our research marked as such, and the notice that
  # results are no certification. The overview ends with "About these checks":
  # services of other operators listed without their consent, no quality seal
  # and no endorsement, the role of OwnYourData, and how operators ask for
  # correction or removal; every detail page repeats it in short. The pages
  # have no external resources.
  class Site
    CRITERIA_REPO = "https://github.com/OwnYourData/dpp-criteria".freeze
    REPO = "https://github.com/OwnYourData/dpp-validator".freeze
    DPP_SERVICE_URL = "https://dpp-service.ownyourdata.eu/".freeze
    SERVICES_README = "#{CRITERIA_REPO}/blob/main/services/README.md".freeze
    DEFAULT_SITE_URL = "https://ownyourdata.github.io/dpp-validator/".freeze
    MARK = File.expand_path("../../assets/oyd-mark.svg", __dir__)
    OPERATOR_URL = "https://www.ownyourdata.eu/en/".freeze
    IMPRINT_URL = "https://www.ownyourdata.eu/en/imprint/".freeze
    PRIVACY_URL = "https://dpp-service.ownyourdata.eu/privacy".freeze
    ORDER = { "failed" => 0, "warning" => 1, "passed" => 2, "skipped" => 3 }.freeze
    REASON_LABELS = {
      "not_applicable" => "not applicable", "not_implemented" => "not implemented", "no_evidence" => "no evidence",
      "needs_credentials" => "needs credentials", "not_sent" => "not sent (read-only run)",
      "unreachable" => "unreachable", "not_evaluated" => "not evaluated"
    }.freeze
    NOT_CHECKED = {
      "needs_credentials" => "not checked: the EN 18222 paths answer only with credentials",
      "no_public_instance" => "not checked: no public instance",
      "no_en18222_paths" => "not checked: no EN 18222 paths found"
    }.freeze
    SOURCE_LABELS = { "operator" => "Entry maintained by the operator", "research" => "Entry from our research" }.freeze
    RESEARCH_NOTICE = "This list is part of a research project and shares what we currently know. It makes no claim to be " \
                      "complete and is not a legal assessment. Entries from our research come from public information and " \
                      "may be incomplete or out of date.".freeze
    CONTACT = "office@ownyourdata.eu".freeze
    REQUESTS_URL = "#{REPO}#listing-correction-and-removal".freeze
    ISSUES_URL = "#{CRITERIA_REPO}/issues".freeze
    # Disclosure on the overview ("About these checks") and, shorter, on every
    # detail page; README "Listing, correction and removal" says the same.
    OTHERS_NOTICE = "Since 18 October 2026 this list also includes services of other operators that we found in our own " \
                    "research. They are listed and checked without the consent of their operators, only through " \
                    "endpoints that anyone can reach on the public internet.".freeze
    NO_SEAL_NOTICE = "The results are no quality seal and no certification, and they imply no endorsement by anyone: " \
                     "listing a service does not mean that its operator agrees with the criteria or the results.".freeze
    OWN_ROLE_NOTICE = "OwnYourData maintains the criteria, runs dpp-validator and dpplint, and operates one of the listed " \
                      "services, the OwnYourData DPP Service, which goes through the same checks as every other entry. It " \
                      "is shown first because these pages are linked from its start page; the order is no ranking.".freeze
    REQUESTS_NOTICE = "An operator can ask at any time for its entry to be corrected or removed. We answer within five " \
                      "working days; a removal takes effect within five working days at the latest.".freeze
    DETAIL_DISCLOSURE = "OwnYourData maintains the criteria, runs these checks and operates one of the listed services. " \
                        "Operators can ask at any time for their entry to be corrected or removed.".freeze

    # services: entries of services/ ([Service]); without them the entries are
    # taken from the validator results.
    def initialize(results_dir:, output_dir:, services: nil, site_url: DEFAULT_SITE_URL, this_service: nil, now: Time.now.utc)
      @results_dir = results_dir
      @output_dir = output_dir
      @services = services
      @site_url = site_url
      @this_service = this_service
      @now = now
    end

    # Writes the site; returns the number of entries on it.
    def build
      results = load(File.join(@results_dir, "*.json")).to_h { |r| [r.dig("service", "id"), r] }
      lints = load(File.join(@results_dir, "linter", "*.json")).to_h { |l| [l["service_id"], l] }
      services = @services || results.values.map { |r| service_from_result(r["service"]) }
      raise Error, "no service entries and no JSON results in #{@results_dir}" if services.empty?

      ids = services.map(&:id)
      results.select! { |id, _| ids.include?(id) }
      lints.select! { |id, _| ids.include?(id) }
      available = Available.new(services: services, results: results, lints: lints, site_url: @site_url,
                                this_service: @this_service, now: @now)
      write_json("results", results)
      write_json("linter", lints)
      FileUtils.mkdir_p(File.join(@output_dir, "services"))
      FileUtils.cp(MARK, File.join(@output_dir, "oyd-mark.svg"))
      ordered = available.ordered
      File.write(File.join(@output_dir, "index.html"), page("DPP service checks", index_body(ordered, results, lints), depth: 0))
      ordered.each do |s|
        File.write(File.join(@output_dir, "services", "#{s.id}.html"),
                   page("#{s.name} – DPP service checks", detail_body(s, results[s.id], lints[s.id]), depth: 1))
      end
      File.write(File.join(@output_dir, "available-services.json"), "#{available.to_json}\n")
      services.size
    end

    private

    def load(pattern) = Dir[pattern].sort.map { |f| JSON.parse(File.read(f, encoding: "UTF-8")) }

    # An entry rebuilt from the service part of a validator result.
    def service_from_result(s)
      operator = { "name" => s["operator"], "url" => s["operator_url"], "country" => s["country"] }.compact
      Service.new(s.merge("operator" => operator))
    end

    def write_json(dir, by_id)
      FileUtils.mkdir_p(File.join(@output_dir, dir))
      by_id.each { |id, data| File.write(File.join(@output_dir, dir, "#{id}.json"), "#{JSON.pretty_generate(data)}\n") }
    end

    def h(text) = CGI.escapeHTML(text.to_s)

    def reason_label(code) = REASON_LABELS.fetch(code.to_s, code.to_s)

    # "5 of 5 passed · 1 warning"
    def short(passed, total, warnings)
      text = "#{passed} of #{total} passed"
      warnings.to_i.positive? ? "#{text} · #{warnings} warning#{'s' if warnings.to_i > 1}" : text
    end

    # "3 skipped: 2 not applicable, 1 needs credentials"; older results
    # without skipped_by_reason give "3 skipped".
    def skipped_text(summary)
      text = "#{summary['skipped'].to_i} skipped"
      by_reason = summary["skipped_by_reason"] || {}
      by_reason.empty? ? text : "#{text}: #{by_reason.map { |code, n| "#{n} #{reason_label(code)}" }.join(', ')}"
    end

    def link(url, text) = url.to_s.empty? ? h(text) : %(<a href="#{h(url)}">#{h(text)}</a>)

    def operator_text(s)
      [s.data.dig("operator", "name"), s.data.dig("operator", "country")].compact.join(" · ")
    end

    def entry_text(s)
      s.research? ? "#{SOURCE_LABELS['research']} · as of #{s.as_of}" : SOURCE_LABELS["operator"]
    end

    def check_text(s, result)
      return NOT_CHECKED.fetch(s.check_reason.to_s, "not checked") unless s.checked?

      plan = if s.test_instance? then "full, weekly, on our own test instance"
             elsif s.read_only? then "read-only, weekly"
             else "full, daily"
             end
      return "first run pending · #{plan}" unless result

      summary = result["summary"] || {}
      passed = summary["passed"].to_i
      version = result.dig("test_instance", "version")
      plan = "#{plan} (version #{version})" if s.test_instance? && version
      "#{short(passed, passed + summary['failed'].to_i, summary['warnings'])} · #{plan}"
    end

    def test_instance_text(s)
      ti = s.test_instance
      %(#{h(ti['configuration'])} <a href="#{h(ti['setup'])}">Setup</a>)
    end

    def passport_texts(s, lint)
      return [%(<span class="muted">no public example passport</span>)] if s.example_passports.empty?

      checked = Array(lint&.dig("passports")).to_h { |p| [p["product_id"], p] }
      s.example_passports.map do |p|
        r = checked[p["product_id"]]
        status = if r.nil? then %(<span class="muted">first check pending</span>)
                 elsif r["status"] != "checked" then %(<span class="muted">#{h(r['error'])}</span>)
                 else h(short(r.dig("summary", "passed"), r.dig("summary", "total"), r.dig("summary", "warnings")))
                 end
        url = r&.dig("lint_url") || Linter.lint_url(p["product_id"])
        %(#{link(url, p['label'])}: #{status})
      end
    end

    def index_body(services, results, lints)
      rows = services.map do |s|
        <<~HTML.chomp
          <tr><td><a href="services/#{h(s.id)}.html">#{h(s.name)}</a><br><span class="muted">#{h(operator_text(s))}</span></td>
          <td>#{h(entry_text(s))}</td>
          <td>#{h(s.licence['text'])}</td>
          <td>#{passport_texts(s, lints[s.id]).join('<br>')}</td>
          <td>#{h(check_text(s, results[s.id]))}#{declarations_note(s, results[s.id])}</td></tr>
        HTML
      end
      <<~HTML
        <h1>DPP service checks</h1>
        <p>DPP services that implement or relate to EN 18222, with automated checks against the criteria of
        <a href="#{CRITERIA_REPO}">dpp-criteria</a>: example passports are checked with
        <a href="https://dpplint.ownyourdata.eu">dpplint</a>, the services with
        <a href="https://github.com/OwnYourData/dpp-validator">dpp-validator</a>. Entries maintained by the operator are
        checked in full every day, entries from our research read-only once a week; open software without a public
        instance is checked in full once a week on a short-lived test instance of our own, started with the current
        release and discarded after the run.
        Only criteria with status <em>active</em> count in &ldquo;N of M&rdquo;; warnings are included in the passed ones.</p>
        <p class="notice">#{h(RESEARCH_NOTICE)} Operators can correct or take over an entry, or ask for its removal:
        <a href="#{SERVICES_README}">how to add or correct a service</a>. #{h(Report::NOTICE)}
        Who runs these checks and how they treat services of other operators: <a href="#about">About these checks</a>.</p>
        <div class="scroll"><table>
        <thead><tr><th>Service</th><th>Entry</th><th>Licence</th><th>Example passports &middot; dpplint</th><th>Service checks &middot; dpp-validator</th></tr></thead>
        <tbody>
        #{rows.join("\n")}
        </tbody></table></div>
        <p class="muted">Machine-readable: <a href="available-services.json">available-services.json</a>.</p>
        #{about_section}
      HTML
    end

    def about_section
      <<~HTML.chomp
        <h2 id="about">About these checks</h2>
        <p>#{h(OTHERS_NOTICE)}</p>
        <p>#{h(NO_SEAL_NOTICE)}</p>
        <p>#{h(OWN_ROLE_NOTICE)}</p>
        <p>#{h(REQUESTS_NOTICE)} Write to <a href="mailto:#{CONTACT}">#{CONTACT}</a> or open an
        <a href="#{ISSUES_URL}">issue in dpp-criteria</a>; <a href="#{REQUESTS_URL}">how we handle requests</a>.</p>
      HTML
    end

    def detail_body(s, result, lint)
      <<~HTML
        <p><a href="../index.html">All services</a></p>
        <h1>#{h(s.name)}</h1>
        <p><strong>#{h(SOURCE_LABELS.fetch(s.source))}</strong>#{s.research? ? " &middot; information as of #{h(s.as_of)}" : ''}</p>
        <dl>
          <dt>Operator</dt><dd>#{link(s.data.dig('operator', 'url'), operator_text(s))}</dd>
          #{s.url ? %(<dt>Web page</dt><dd>#{link(s.url, s.url)}</dd>) : ''}
          #{s.data['source_code'] ? %(<dt>Source code</dt><dd>#{link(s.data['source_code'], s.data['source_code'])}</dd>) : ''}
          <dt>Licence</dt><dd>#{h(s.licence['text'])}#{Array(s.licence['spdx']).any? ? %( <span class="muted">(SPDX: #{h(s.licence['spdx'].join(', '))})</span>) : ''}</dd>
          #{s.api_base ? %(<dt>API base</dt><dd>#{h(s.api_base)}</dd>) : ''}
          #{s.data['contact'] ? %(<dt>Contact</dt><dd><a href="mailto:#{h(s.data['contact'])}">#{h(s.data['contact'])}</a></dd>) : ''}
          <dt>Checks</dt><dd>#{h(check_text(s, result))}</dd>
          #{s.test_instance? ? %(<dt>Test instance</dt><dd>#{test_instance_text(s)}</dd>) : ''}
          <dt>Listed since</dt><dd>#{h(s.data['listed_since'].to_s.empty? ? '–' : s.data['listed_since'])}</dd>
          <dt>Entry</dt><dd><a href="#{CRITERIA_REPO}/blob/main/services/#{h(s.id)}.yaml">services/#{h(s.id)}.yaml</a></dd>
        </dl>
        #{s.notes ? %(<p>#{h(s.notes)}</p>) : ''}
        #{s.research? ? %(<p class="notice">#{h(RESEARCH_NOTICE)} The operator can correct or take over this entry, or ask for its removal: <a href="#{SERVICES_README}">how to add or correct a service</a>.</p>) : ''}
        <h2>Example passports &middot; dpplint</h2>
        #{lint_section(s, lint)}
        <h2>Service checks &middot; dpp-validator</h2>
        #{validator_section(s, result)}
        #{declarations_section(result)}
        <p class="notice">#{h(Report::NOTICE)}</p>
        <p class="notice">#{h(DETAIL_DISCLOSURE)} Write to <a href="mailto:#{CONTACT}">#{CONTACT}</a>;
        <a href="../index.html#about">about these checks</a>.</p>
      HTML
    end

    def lint_section(s, lint)
      return %(<p class="muted">No public example passport.</p>) if s.example_passports.empty?

      checked = Array(lint&.dig("passports")).to_h { |p| [p["product_id"], p] }
      s.example_passports.map do |p|
        r = checked[p["product_id"]]
        url = r&.dig("lint_url") || Linter.lint_url(p["product_id"])
        head = %(<h3>#{h(p['label'])}</h3><p class="muted">#{h(p['product_id'])} &middot; <a href="#{h(url)}">open in dpplint</a></p>)
        next "#{head}<p class=\"muted\">First check pending.</p>" unless r
        next "#{head}<p class=\"muted\">#{h(r['error'])}</p>" unless r["status"] == "checked"

        sm = r["summary"]
        shown = Array(r["criteria"]).select { |c| c["status"] == "active" || c.key?("history") }
        <<~HTML.chomp
          #{head}
          <div class="summary"><strong>#{h(sm['text'])}</strong> (#{h(sm['failed'])} failed, #{h(sm['warnings'])} with warnings, #{h(sm['skipped'])} skipped) &middot; checked #{h(lint['checked_at'].to_s[0, 10])}
            <div class="notice">Proposed criteria failed, not counted: #{h(sm['proposed_failed'])}</div></div>
          <div class="scroll"><table>
          <thead><tr><th>Criterion</th><th>Title</th><th>Result</th></tr></thead>
          <tbody>
          #{shown.sort_by { |c| [c['status'] == 'active' ? 0 : 1, ORDER.fetch(c['result'], 9), c['id']] }.map { |c| lint_row(c) }.join("\n")}
          </tbody></table></div>
        HTML
      end.join("\n")
    end

    # A criterion that dpp-validator rates from the stored runs (history) is
    # shown with its message, also while it is proposed.
    def lint_row(c)
      id = c["description_url"] ? link(c["description_url"], c["id"]) : h(c["id"])
      reason = c["reason_code"] ? %(<br><span class="muted">#{h(reason_label(c['reason_code']))}</span>) : ""
      marker = c["status"] == "active" ? "" : %( <span class="muted">(#{h(c['status'])}, not counted)</span>)
      note = c["message"] ? %(<ul class="msg"><li>rated by dpp-validator from its stored runs: #{h(c['message'])}</li></ul>) : ""
      %(<tr><td class="id">#{id}</td><td>#{h(c['title'])}#{marker}#{note}</td><td><span class="badge #{h(c['result'])}">#{h(c['result'])}</span>#{reason}</td></tr>)
    end

    def validator_section(s, r)
      return %(<p class="muted">#{h(check_text(s, nil).capitalize)}.</p>) unless s.checked? && r

      commit = r.dig("dpp_criteria", "commit").to_s
      summary = r["summary"] || {}
      proposed = summary["proposed_not_counted"] || {}
      <<~HTML
        <p class="muted">Run #{h(r['run_at'])} &middot; dpp-criteria <a href="#{CRITERIA_REPO}/tree/#{h(commit)}">#{h(commit[0, 7])}</a> &middot; <a href="../results/#{h(s.id)}.json">JSON</a></p>
        <div class="summary"><strong>#{h(summary['text'])}</strong>
          (#{h(summary['failed'])} failed, #{h(summary['warnings'])} with warnings, #{h(skipped_text(summary))})#{mode_text(r)}
          <div class="notice">Proposed criteria, not counted: #{h(proposed['text'])}</div></div>
        <div class="scroll"><table>
        <thead><tr><th>Criterion</th><th>Requirement and findings</th><th>Level</th><th>Result</th></tr></thead>
        <tbody>
        #{rows(r['criteria'] || [], commit, declared_ids(r))}
        </tbody></table></div>
      HTML
    end

    def declarations(r) = Array(r&.dig("declarations", "items"))

    # Overview: the number of self-declarations in the latest result, linked to
    # their section on the detail page; nothing without any.
    def declarations_note(s, r)
      n = declarations(r).size
      return "" if n.zero?

      %(<br><a class="muted" href="services/#{h(s.id)}.html#self-declarations">#{n} self-declaration#{'s' unless n == 1}, not counted</a>)
    end

    def declared_ids(r) = declarations(r).map { |d| d["criterion"] }

    def declaration_anchor(id) = "declaration-#{id.to_s.downcase}"

    # The self-declarations of the operator, apart from the checks: statement
    # and evidence link as given, no result and no badge.
    def declarations_section(r)
      items = declarations(r)
      return "" if items.empty?

      commit = r.dig("dpp_criteria", "commit").to_s
      blocks = items.map do |d|
        id = d["criterion"].to_s
        url = d["description_url"] ||
              "#{CRITERIA_REPO}/blob/#{commit}/criteria/#{id.split('-')[1].to_s.downcase}/#{id}.yaml"
        status = d["status"] ? %( <span class="muted">(criterion #{h(d['status'])})</span>) : ""
        <<~HTML.chomp
          <div class="decl" id="#{h(declaration_anchor(id))}">
          <p><span class="id"><a href="#{h(url)}" title="Description of the criterion">#{h(id)}</a></span> #{h(d['title'])}#{status}</p>
          <p>#{h(d['statement'])}</p>
          <p class="muted">Evidence: #{link(d['evidence'], d['evidence'])}</p>
          </div>
        HTML
      end
      <<~HTML
        <h2 id="self-declarations">Self-declarations of the operator</h2>
        <p class="notice">#{h(r.dig('declarations', 'notice') || Report::DECLARATIONS_NOTICE)}</p>
        #{blocks.join("\n")}
      HTML
    end

    def mode_text(r)
      case r["mode"]
      when "read-only" then " &middot; read-only run"
      when "test-instance"
        ti = r["test_instance"] || {}
        name = [ti["software"], ti["version"]].compact.join(" ")
        release = ti["release"] ? %( (<a href="#{h(ti['release'])}">release</a>)) : ""
        " &middot; on our own test instance: #{h(name)}#{release}"
      else ""
      end
    end

    def rows(criteria, commit, declared = [])
      criteria.sort_by { |c| [c["counted"] || c["status"] == "active" ? 0 : 1, ORDER.fetch(c["result"], 9), c["id"]] }.map do |c|
        notes = Array(c["messages"]).map { |m| "<li>#{h(m['severity'])}: #{h(m['message'])}</li>" }
        notes << "<li>#{h(c['reason'])}</li>" if c["reason"]
        notes << %(<li><a href="##{h(declaration_anchor(c['id']))}">Self-declaration of the operator</a></li>) if declared.include?(c["id"])
        marker = c["status"] == "active" ? "" : %( <span class="muted">(#{h(c['status'])}, not counted)</span>)
        link = c["description_url"] ||
               "#{CRITERIA_REPO}/blob/#{commit}/criteria/#{c['id'].to_s.split('-')[1].to_s.downcase}/#{c['id']}.yaml"
        <<~HTML.chomp
          <tr><td class="id"><a href="#{h(link)}" title="Description of the criterion">#{h(c['id'])}</a> v#{h(c['version'])}</td>
          <td>#{h(c['title'])}#{marker}#{notes.empty? ? '' : %(<ul class="msg">#{notes.join}</ul>)}</td>
          <td>#{h(c['level'])}</td><td><span class="badge #{h(c['result'])}">#{h(c['result'])}</span>#{c['reason_code'] ? %(<br><span class="muted">#{h(reason_label(c['reason_code']))}</span>) : ''}</td></tr>
        HTML
      end.join("\n")
    end

    def page(title, body, depth:)
      up = "../" * depth
      <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{h(title)}</title>
        <link rel="icon" href="#{up}oyd-mark.svg" type="image/svg+xml">
        <style>
          :root { --fg: #1d1d1f; --muted: #5f6368; --line: #d9dce1; --panel: #f6f7f9; --bg: #fff;
                  --passed: #1e7a3c; --warning: #8a5a00; --failed: #b3261e; --skipped: #5f6368; }
          @media (prefers-color-scheme: dark) {
            :root { --fg: #e8eaed; --muted: #a0a4aa; --line: #3a3d42; --panel: #202226; --bg: #151618;
                    --passed: #6fcf8f; --warning: #e7b75f; --failed: #f28b82; --skipped: #a0a4aa; }
          }
          body { font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; color: var(--fg); background: var(--bg); margin: 0; }
          .wrap { max-width: 1100px; margin: 0 auto; padding: 0 16px; }
          main.wrap { padding-top: 24px; }
          h1 { font-size: 1.6rem; margin: 0 0 4px; }
          header { padding: 20px 0; border-bottom: 1px solid var(--line); }
          header .wrap { display: flex; justify-content: space-between; align-items: center; gap: 16px; flex-wrap: wrap; }
          header .brand { display: flex; align-items: center; gap: 9px; font-weight: 600; text-decoration: none; }
          header .brand span { color: var(--muted); font-weight: 400; }
          header .brand .mark { width: 15px; height: auto; display: block; }
          header nav a { color: var(--muted); text-decoration: none; margin-left: 18px; font-size: 15px; }
          header nav a:hover { color: var(--fg); }
          @media (max-width: 600px) { header nav a { margin: 0 14px 0 0; } }
          h2 { font-size: 1.25rem; margin: 32px 0 4px; }
          h3 { font-size: 1.05rem; margin: 20px 0 2px; }
          a { color: inherit; }
          .muted, .notice { color: var(--muted); }
          .notice { font-size: .9rem; }
          .summary { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 14px 16px; margin: 12px 0; }
          .summary strong { font-size: 1.2rem; }
          .scroll { overflow-x: auto; }
          table { border-collapse: collapse; width: 100%; min-width: 640px; }
          th, td { text-align: left; vertical-align: top; padding: 7px 8px; border-bottom: 1px solid var(--line); }
          th { font-size: .85rem; color: var(--muted); font-weight: 600; }
          td.id { white-space: nowrap; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .85rem; }
          ul.msg { margin: 4px 0 0; padding-left: 18px; color: var(--muted); font-size: .9rem; }
          .badge { font-weight: 600; }
          .passed { color: var(--passed); } .warning { color: var(--warning); }
          .failed { color: var(--failed); } .skipped { color: var(--skipped); }
          dl { display: grid; grid-template-columns: max-content 1fr; gap: 2px 12px; margin: 8px 0; font-size: .92rem; }
          dt { color: var(--muted); } dd { margin: 0; overflow-wrap: anywhere; }
          .decl { border-left: 3px solid var(--line); padding: 2px 0 2px 12px; margin: 14px 0; }
          .decl p { margin: 4px 0; overflow-wrap: anywhere; }
          .decl .id { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .85rem; }
          footer { margin-top: 56px; padding: 24px 0 40px; border-top: 1px solid var(--line); color: var(--muted); font-size: 14px; }
          footer .wrap { display: flex; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
          footer a { color: var(--muted); }
          footer .legal a { margin-right: 16px; }
          footer .funding { flex-basis: 100%; font-size: 13px; }
        </style>
        </head>
        <body>
        <header>
        <div class="wrap">
        <a class="brand" href="#{up}index.html"><img class="mark" src="#{up}oyd-mark.svg" alt="" width="15" height="28">DPP Service Validator <span>&middot; OwnYourData</span></a>
        <nav><a href="#{DPP_SERVICE_URL}">DPP Service</a><a href="#{REPO}">GitHub</a></nav>
        </div>
        </header>
        <main class="wrap">
        #{body}
        </main>
        <footer>
        <div class="wrap">
        <div>Operated by <a href="#{OPERATOR_URL}">OwnYourData</a></div>
        <div class="legal"><a href="#{IMPRINT_URL}">Imprint</a><a href="#{PRIVACY_URL}">Privacy</a></div>
        <div class="funding">#{Funding.html}</div>
        </div>
        </footer>
        </body>
        </html>
      HTML
    end
  end
end
