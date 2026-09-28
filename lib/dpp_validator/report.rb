module DppValidator
  # Result of one run. "N of M automated checks passed" counts only criteria
  # with status active whose result is passed, warning (passed with a remark)
  # or failed; skipped results are not counted. Proposed criteria are
  # reported separately as "proposed, not counted".
  class Report
    NOTICE = "Results of automated checks only. They are no certification and establish no presumption of conformity.".freeze
    COUNTED = %w[passed warning failed].freeze

    attr_reader :service, :run_at, :criteria_commit, :results, :not_run

    def initialize(service:, run_at:, criteria_commit:, results:, not_run:)
      @service = service
      @run_at = run_at
      @criteria_commit = criteria_commit
      @results = results.map { |r| r.merge("counted" => r["status"] == "active" && COUNTED.include?(r["result"])) }
      @not_run = not_run
    end

    def summary = tally(@results.select { |r| r["status"] == "active" })
    def proposed_summary = tally(@results.select { |r| r["status"] == "proposed" })

    def to_h
      {
        "validator" => { "name" => "dpp-validator", "version" => VERSION },
        "notice" => NOTICE,
        "service" => @service.to_h,
        "run_at" => @run_at.utc.iso8601,
        "dpp_criteria" => { "repository" => "https://github.com/OwnYourData/dpp-criteria", "commit" => @criteria_commit },
        "summary" => summary.merge("proposed_not_counted" => proposed_summary),
        "criteria" => @results,
        "not_run" => @not_run
      }
    end

    def to_json(*args) = JSON.pretty_generate(to_h, *args)

    def to_text
      lines = []
      lines << "dpp-validator #{VERSION}: #{@service.name} (#{@service.api_base})"
      lines << "dpp-criteria #{@criteria_commit}, run #{@run_at.utc.iso8601}"
      lines << "#{summary['text']} (active criteria)"
      p = proposed_summary
      lines << "proposed, not counted: #{p['text']}; #{p['warnings']} with warnings, #{p['skipped']} skipped"
      lines << ""
      @results.each do |r|
        lines << format("%-12s v%-2s %-9s %-8s %s", r["id"], r["version"], r["status"], r["result"], r["title"])
        lines << "    skipped: #{r['reason']}" if r["reason"]
        Array(r["messages"]).each { |m| lines << "    #{m['severity']}: #{m['message']}" }
      end
      lines << ""
      lines << "not run: #{@not_run.size} passport criteria (checked by dpplint)" if @not_run.any?
      lines << NOTICE
      lines.join("\n")
    end

    private

    def tally(list)
      counted = list.select { |r| COUNTED.include?(r["result"]) }
      passed = counted.count { |r| r["result"] != "failed" }
      {
        "text" => "#{passed} of #{counted.size} automated checks passed",
        "passed" => passed,
        "failed" => counted.size - passed,
        "warnings" => list.count { |r| r["result"] == "warning" },
        "skipped" => list.count { |r| r["result"] == "skipped" }
      }
    end
  end
end
