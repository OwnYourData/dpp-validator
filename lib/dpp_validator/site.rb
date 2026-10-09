require "cgi"
require "fileutils"

module DppValidator
  # Static result pages for GitHub Pages: index.html with the latest result of
  # every listed service, and the JSON results next to it (results/<id>.json).
  #
  # Wording follows CRITERIA-FORMAT.md ("Results wording"): "N of M automated
  # checks passed" for active criteria only, proposed criteria marked as not
  # counted, and the notice that results are no certification. The page has
  # no external resources.
  class Site
    CRITERIA_REPO = "https://github.com/OwnYourData/dpp-criteria".freeze
    ORDER = { "failed" => 0, "warning" => 1, "passed" => 2, "skipped" => 3 }.freeze
    REASON_LABELS = {
      "not_applicable" => "not applicable", "not_implemented" => "not implemented", "no_evidence" => "no evidence",
      "needs_credentials" => "needs credentials", "not_sent" => "not sent (read-only run)",
      "unreachable" => "unreachable", "not_evaluated" => "not evaluated"
    }.freeze

    def initialize(results_dir:, output_dir:)
      @results_dir = results_dir
      @output_dir = output_dir
    end

    # Writes the site; returns the number of services on it.
    def build
      results = Dir[File.join(@results_dir, "*.json")].sort.map { |f| JSON.parse(File.read(f)) }
      raise Error, "no JSON results in #{@results_dir}" if results.empty?

      FileUtils.mkdir_p(File.join(@output_dir, "results"))
      results.each do |r|
        File.write(File.join(@output_dir, "results", "#{r.dig('service', 'id')}.json"), "#{JSON.pretty_generate(r)}\n")
      end
      File.write(File.join(@output_dir, "index.html"), page(results))
      results.size
    end

    private

    def h(text) = CGI.escapeHTML(text.to_s)

    def reason_label(code) = REASON_LABELS.fetch(code.to_s, code.to_s)

    # "3 skipped: 2 not applicable, 1 needs credentials"; older results
    # without skipped_by_reason give "3 skipped".
    def skipped_text(summary)
      text = "#{summary['skipped'].to_i} skipped"
      by_reason = summary["skipped_by_reason"] || {}
      by_reason.empty? ? text : "#{text}: #{by_reason.map { |code, n| "#{n} #{reason_label(code)}" }.join(', ')}"
    end

    def page(results)
      <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>DPP service checks</title>
        <style>
          :root { --fg: #1d1d1f; --muted: #5f6368; --line: #d9dce1; --panel: #f6f7f9; --bg: #fff;
                  --passed: #1e7a3c; --warning: #8a5a00; --failed: #b3261e; --skipped: #5f6368; }
          @media (prefers-color-scheme: dark) {
            :root { --fg: #e8eaed; --muted: #a0a4aa; --line: #3a3d42; --panel: #202226; --bg: #151618;
                    --passed: #6fcf8f; --warning: #e7b75f; --failed: #f28b82; --skipped: #a0a4aa; }
          }
          body { font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; color: var(--fg); background: var(--bg);
                 max-width: 1100px; margin: 0 auto; padding: 24px 16px 48px; }
          h1 { font-size: 1.6rem; margin: 0 0 4px; }
          h2 { font-size: 1.25rem; margin: 32px 0 4px; }
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
        </style>
        </head>
        <body>
        <h1>DPP service checks</h1>
        <p>Automated checks of Digital Product Passport services against the criteria of
        <a href="#{CRITERIA_REPO}">dpp-criteria</a>, run daily by
        <a href="https://github.com/OwnYourData/dpp-validator">dpp-validator</a>.
        Only criteria with status <em>active</em> count in &ldquo;N of M&rdquo;; proposed criteria are shown but not counted.
        Passport content is checked by <a href="https://dpplint.ownyourdata.eu">dpplint</a>.</p>
        <p class="notice">#{h(Report::NOTICE)}</p>
        #{results.map { |r| service_section(r) }.join("\n")}
        </body>
        </html>
      HTML
    end

    def service_section(r)
      s = r["service"] || {}
      commit = r.dig("dpp_criteria", "commit").to_s
      summary = r["summary"] || {}
      proposed = summary["proposed_not_counted"] || {}
      <<~HTML
        <section id="#{h(s['id'])}">
        <h2>#{h(s['name'])}</h2>
        <dl>
          <dt>Operator</dt><dd>#{s['operator_url'] ? %(<a href="#{h(s['operator_url'])}">#{h(s['operator'])}</a>) : h(s['operator'])}</dd>
          <dt>API base</dt><dd>#{h(s['api_base'])}</dd>
          <dt>Contact</dt><dd>#{s['contact'] ? %(<a href="mailto:#{h(s['contact'])}">#{h(s['contact'])}</a>) : "&ndash;"}</dd>
          <dt>Listed since</dt><dd>#{h(s['listed_since'].to_s.empty? ? '–' : s['listed_since'])}</dd>
          <dt>Run</dt><dd>#{h(r['run_at'])} &middot; dpp-criteria <a href="#{CRITERIA_REPO}/tree/#{h(commit)}">#{h(commit[0, 7])}</a> &middot; <a href="results/#{h(s['id'])}.json">JSON</a></dd>
        </dl>
        <div class="summary"><strong>#{h(summary['text'])}</strong>
          (#{h(summary['failed'])} failed, #{h(summary['warnings'])} with warnings, #{h(skipped_text(summary))})#{r['mode'] == 'read-only' ? ' &middot; read-only run' : ''}
          <div class="notice">Proposed criteria, not counted: #{h(proposed['text'])}</div></div>
        <div class="scroll"><table>
        <thead><tr><th>Criterion</th><th>Requirement and findings</th><th>Level</th><th>Result</th></tr></thead>
        <tbody>
        #{rows(r['criteria'] || [], commit)}
        </tbody></table></div>
        </section>
      HTML
    end

    def rows(criteria, commit)
      criteria.sort_by { |c| [c["counted"] || c["status"] == "active" ? 0 : 1, ORDER.fetch(c["result"], 9), c["id"]] }.map do |c|
        notes = Array(c["messages"]).map { |m| "<li>#{h(m['severity'])}: #{h(m['message'])}</li>" }
        notes << "<li>#{h(c['reason'])}</li>" if c["reason"]
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
  end
end
