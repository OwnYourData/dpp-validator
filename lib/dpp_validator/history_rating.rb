module DppValidator
  # Rates the passport criteria with `check.history` (DPP-ID-002; "Check
  # types", resolve, in CRITERIA-FORMAT.md) from the stored runs, i.e. the
  # directory runs/ of the branch results: runs/<date>/linter/<service id>.json.
  #
  # For every example passport the result of `history.criterion` is taken from
  # the stored runs of the last `history.period_days` days before today and
  # from today's dpplint result. A run in which that criterion has no result
  # (skipped, not listed, dpplint not reachable) is left out; passed and
  # warning count as success. Runs stored under today's date are earlier runs
  # of the same day and are replaced by today's result.
  #
  # - fewer runs than fail_after_consecutive_runs: skipped (not_evaluated)
  # - that many consecutive failures within the period: failed
  # - failures in single runs only: warning
  # - otherwise: passed
  #
  # The entry of the criterion in the dpplint result (dpplint skips it) is
  # replaced; the summary of the passport is counted again, as dpplint counts
  # ("Results" in CRITERIA-FORMAT.md).
  class HistoryRating
    KEYS = %w[criterion period_days fail_after_consecutive_runs].freeze
    SUCCESS = %w[passed warning].freeze
    FAILURE = "failed".freeze
    LISTED_DATES = 5

    # criteria: CriteriaRepository::Criterion list; runs_dir: the directory
    # runs/ of the stored results; today: Date (UTC) of this run.
    def initialize(criteria:, runs_dir:, today:)
      @rated = criteria.select do |c|
        history = c.data.dig("check", "history")
        c.schema_errors.empty? && c["target"] == "passport" && history.is_a?(Hash) && KEYS.all? { |k| history.key?(k) }
      end
      @runs_dir = runs_dir
      @today = today
      @stored = {}
    end

    def any? = @rated.any?

    # result: the linter result of one service (Linter#run). Returns it with
    # the rated criteria of every checked passport.
    def apply(result)
      return result if @rated.empty?

      service_id = result["service_id"]
      passports = Array(result["passports"]).map { |p| rate_passport(service_id, p) }
      result.merge("passports" => passports)
    end

    private

    def rate_passport(service_id, passport)
      return passport unless passport["status"] == "checked" && passport["criteria"].is_a?(Array)

      criteria = passport["criteria"].map do |entry|
        criterion = @rated.find { |c| c.id == entry["id"] }
        criterion ? rated_entry(entry, criterion, service_id, passport) : entry
      end
      return passport if criteria == passport["criteria"]

      passport.merge("criteria" => criteria, "summary" => Linter.summary_of(criteria))
    end

    def rated_entry(entry, criterion, service_id, passport)
      history = criterion.data.dig("check", "history")
      source = history["criterion"]
      period = history["period_days"].to_i
      needed = history["fail_after_consecutive_runs"].to_i
      runs = runs_for(service_id, passport, source, period)
      base = entry.slice("id", "title", "status", "description_url")
      info = { "criterion" => source, "period_days" => period, "runs" => runs.size,
               "failed" => runs.count { |_, ok| !ok }, "from" => runs.first&.first&.iso8601, "to" => runs.last&.first&.iso8601 }

      if runs.size < needed
        found = runs.empty? ? "no result in the runs" : "a result in only #{runs.size} run#{'s' unless runs.size == 1}"
        return base.merge("result" => "skipped", "reason_code" => "not_evaluated", "history" => info,
                          "message" => "#{source} has #{found} of the last #{period} days; the rating needs at least #{needed} runs")
      end

      failed_dates = runs.reject { |_, ok| ok }.map(&:first)
      streak = longest_failure_streak(runs)
      result, message =
        if streak.size >= needed
          ["failed", "#{source} failed in #{streak.size} consecutive runs: #{dates(streak)}"]
        elsif failed_dates.any?
          ["warning", "#{source} failed in #{failed_dates.size} of #{runs.size} runs from #{info['from']} to #{info['to']}: #{dates(failed_dates)}"]
        else
          ["passed", "#{source} passed in all #{runs.size} runs from #{info['from']} to #{info['to']}"]
        end
      base.merge("result" => result, "history" => info, "message" => message)
    end

    # [[date, success?], ...], oldest first, only runs with a result.
    def runs_for(service_id, passport, source, period)
      runs = (1...period).to_a.reverse.filter_map do |days_ago|
        date = @today - days_ago
        stored = stored_passport(service_id, date, passport["product_id"])
        ok = success(stored, source)
        [date, ok] unless ok.nil?
      end
      today = success(passport, source)
      today.nil? ? runs : runs + [[@today, today]]
    end

    # true, false or nil (no result).
    def success(passport, source)
      return nil unless passport && passport["status"] == "checked"

      result = Array(passport["criteria"]).find { |c| c["id"] == source }&.dig("result")
      return true if SUCCESS.include?(result)

      result == FAILURE ? false : nil
    end

    def stored_passport(service_id, date, product_id)
      run = @stored[[service_id, date]] ||= load_run(service_id, date)
      Array(run && run["passports"]).find { |p| p["product_id"] == product_id }
    end

    def load_run(service_id, date)
      path = File.join(@runs_dir, date.iso8601, "linter", "#{service_id}.json")
      File.file?(path) ? JSON.parse(File.read(path)) : nil
    rescue JSON::ParserError
      nil
    end

    # Dates of the longest sequence of consecutive failed runs (the latest of
    # equally long ones).
    def longest_failure_streak(runs)
      best = []
      current = []
      runs.each do |date, ok|
        current = ok ? [] : current + [date]
        best = current if current.size >= best.size && current.any?
      end
      best
    end

    def dates(list)
      shown = list.first(LISTED_DATES).map(&:iso8601)
      list.size > LISTED_DATES ? "#{shown.join(', ')} and #{list.size - LISTED_DATES} more" : shown.join(", ")
    end
  end
end
