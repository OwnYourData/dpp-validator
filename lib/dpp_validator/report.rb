module DppValidator
  # Result of one run. "N of M automated checks passed" counts only criteria
  # with status active whose result is passed, warning (passed with a remark)
  # or failed; skipped results are not counted. Proposed criteria are
  # reported separately as "proposed, not counted". Skipped criteria are
  # counted per reason_code (skipped_by_reason). mode is "full",
  # "read-only" (only GET, HEAD and OPTIONS sent) or "test-instance" (in full,
  # on our own short-lived test instance; test_instance names the software
  # version, the images and the test passport, but not the internal API base).
  #
  # declarations lists the self-declarations of the entry apart from the
  # results: the statement and the evidence link as the operator gives them,
  # with the title and status of the criterion. They are not checked and never
  # enter a summary; the self-declared criteria themselves stay skipped.
  class Report
    NOTICE = "Results of automated checks only. They are no certification and establish no presumption of conformity.".freeze
    DECLARATIONS_NOTICE = "Statements of the operator about the service, with a link to its evidence, listed as given. " \
                          "They are not checked and never count as passed.".freeze
    COUNTED = %w[passed warning failed].freeze

    attr_reader :service, :run_at, :criteria_commit, :results, :not_run, :declarations

    PUBLIC_TEST_INSTANCE = %w[software version release images started_at setup test_passport test_data].freeze

    def initialize(service:, run_at:, criteria_commit:, results:, not_run:, declarations: [], read_only: false, test_instance: nil)
      @service = service
      @run_at = run_at
      @criteria_commit = criteria_commit
      @read_only = read_only
      @test_instance = test_instance
      @results = results.map { |r| r.merge("counted" => r["status"] == "active" && COUNTED.include?(r["result"])) }
      @not_run = not_run
      @declarations = declarations
    end

    def summary = tally(@results.select { |r| r["status"] == "active" })
    def proposed_summary = tally(@results.select { |r| r["status"] == "proposed" })

    def to_h
      {
        "validator" => { "name" => "dpp-validator", "version" => VERSION },
        "notice" => NOTICE,
        "service" => @test_instance ? @service.to_h.except("api_base") : @service.to_h,
        "run_at" => @run_at.utc.iso8601,
        "mode" => mode,
        "test_instance" => @test_instance&.slice(*PUBLIC_TEST_INSTANCE),
        "dpp_criteria" => { "repository" => "https://github.com/OwnYourData/dpp-criteria", "commit" => @criteria_commit },
        "summary" => summary.merge("proposed_not_counted" => proposed_summary),
        "criteria" => @results,
        "declarations" => (declarations_h if @declarations.any?),
        "not_run" => @not_run
      }.compact
    end

    def to_json(*args) = JSON.pretty_generate(to_h, *args)

    def to_text
      lines = []
      lines << "dpp-validator #{VERSION}: #{@service.name} (#{@test_instance ? test_instance_text : @service.api_base})"
      lines << "dpp-criteria #{@criteria_commit}, run #{@run_at.utc.iso8601}"
      lines << "read-only run: only GET, HEAD and OPTIONS requests were sent" if @read_only
      lines << "#{summary['text']} (active criteria)"
      lines << "skipped: #{by_reason_text(summary)}" if summary["skipped"].positive?
      p = proposed_summary
      lines << "proposed, not counted: #{p['text']}; #{p['warnings']} with warnings, #{p['skipped']} skipped"
      lines << ""
      @results.each do |r|
        lines << format("%-12s v%-2s %-9s %-8s %s", r["id"], r["version"], r["status"], r["result"], r["title"])
        lines << "    skipped (#{r['reason_code']}): #{r['reason']}" if r["reason"]
        Array(r["messages"]).each { |m| lines << "    #{m['severity']}: #{m['message']}" }
      end
      if @declarations.any?
        lines << ""
        lines << "self-declarations of the operator (listed, not checked, not counted): #{@declarations.size}"
        @declarations.each { |d| lines << format("%-12s %s", d["criterion"], d["evidence"]) }
      end
      lines << ""
      lines << "not run: #{@not_run.size} passport criteria (checked by dpplint)" if @not_run.any?
      lines << NOTICE
      lines.join("\n")
    end

    def mode
      return "test-instance" if @test_instance

      @read_only ? "read-only" : "full"
    end

    def test_instance_text = "our own test instance, #{[@test_instance['software'], @test_instance['version']].compact.join(' ')}"

    private

    def declarations_h = { "notice" => DECLARATIONS_NOTICE, "items" => @declarations }

    def by_reason_text(tally) = tally["skipped_by_reason"].map { |code, n| "#{n} #{code}" }.join(", ")

    def tally(list)
      counted = list.select { |r| COUNTED.include?(r["result"]) }
      passed = counted.count { |r| r["result"] != "failed" }
      {
        "text" => "#{passed} of #{counted.size} automated checks passed",
        "passed" => passed,
        "failed" => counted.size - passed,
        "warnings" => list.count { |r| r["result"] == "warning" },
        "skipped" => list.count { |r| r["result"] == "skipped" },
        "skipped_by_reason" => Checks::REASON_CODES.to_h { |code| [code, list.count { |r| r["reason_code"] == code }] }.reject { |_, n| n.zero? }
      }
    end
  end
end
