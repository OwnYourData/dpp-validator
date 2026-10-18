module DppValidator
  # available-services.json: every entry of services/ with its latest
  # results, for pages that show the list (e.g. the start page of a DPP
  # service). Format in README.md ("available-services.json").
  #
  # Counting, for the linter and the validator alike: `passed` are the active
  # criteria with result passed or warning, `failed` those with result
  # failed, `total` = passed + failed, `warnings` how many of the passed ones
  # have a warning (they are included in passed). Skipped criteria are not
  # counted. summary_text is the text of dpplint or dpp-validator, e.g.
  # "5 of 5 automated checks passed"; a page shows it as
  # "5 of 5 passed · 1 warning".
  class Available
    NOTICE = "Results of automated checks only, from a research project that shares what we currently know. " \
             "The list is not complete and no legal assessment; the results are no certification and establish no " \
             "presumption of conformity. Entries from our research come from our own research and may be incomplete " \
             "or out of date.".freeze
    COUNTING = "passed: active criteria with result passed or warning; failed: result failed; total: passed + failed; " \
               "warnings: passed with a warning, included in passed; skipped criteria are not counted".freeze

    # services: [Service]; results: { id => validator result hash };
    # lints: { id => linter result hash }; site_url: base URL of the result pages.
    def initialize(services:, results:, lints:, site_url:, this_service: nil, now: Time.now.utc)
      @services = services
      @results = results
      @lints = lints
      @site_url = site_url.end_with?("/") ? site_url : "#{site_url}/"
      @this_service = this_service
      @now = now
    end

    def to_h
      {
        "generated_at" => @now.utc.iso8601,
        "notice" => NOTICE,
        "counting" => COUNTING,
        "services" => ordered.map { |s| entry(s) }
      }
    end

    def to_json(*args) = JSON.pretty_generate(to_h, *args)

    # This service first, then operator entries, then research entries, each by name.
    def ordered
      @services.sort_by { |s| [s.id == @this_service ? 0 : 1, s.research? ? 1 : 0, s.name.to_s.downcase] }
    end

    def details_url(service) = "#{@site_url}services/#{service.id}.html"

    private

    def entry(service)
      {
        "id" => service.id,
        "name" => service.name,
        "url" => service.url,
        "provider" => { "name" => service.data.dig("operator", "name"), "country" => service.data.dig("operator", "country") },
        "this_service" => service.id == @this_service,
        "entry" => { "source" => service.source, "as_of" => service.as_of },
        "licence" => { "text" => service.licence["text"], "spdx" => Array(service.licence["spdx"]) },
        "linter" => linter(service),
        "validator" => validator(service)
      }
    end

    def linter(service)
      return { "passports" => [], "note" => "no public example passport" } if service.example_passports.empty?

      checked = Array(@lints.dig(service.id, "passports")).to_h { |p| [p["product_id"], p] }
      checked_at = @lints.dig(service.id, "checked_at").to_s[0, 10]
      passports = service.example_passports.map do |p|
        base = { "product_id" => p["product_id"], "label" => p["label"], "lint_url" => Linter.lint_url(p["product_id"], @lints.dig(service.id, "dpplint") || Linter::DEFAULT_URL) }
        result = checked[p["product_id"]]
        if result.nil?
          base.merge("summary_text" => nil, "passed" => nil, "total" => nil, "failed" => nil, "warnings" => nil,
                     "checked_at" => nil, "note" => "first check pending")
        elsif result["status"] != "checked"
          base.merge("summary_text" => nil, "passed" => nil, "total" => nil, "failed" => nil, "warnings" => nil,
                     "checked_at" => checked_at, "note" => result["error"])
        else
          s = result["summary"]
          base.merge("summary_text" => s["text"], "passed" => s["passed"], "total" => s["total"], "failed" => s["failed"],
                     "warnings" => s["warnings"], "checked_at" => checked_at, "note" => nil)
        end
      end
      { "passports" => passports }
    end

    # mode: "full", "read-only" or "test-instance" (in full, on our own
    # short-lived test instance; test_instance names the software and version
    # of the last run).
    def validator(service)
      return { "status" => service.check_reason } unless service.checked?

      mode = if service.test_instance? then "test-instance"
             elsif service.read_only? then "read-only"
             else "full"
             end
      head = { "mode" => mode, "cadence" => service.cadence, "details_url" => details_url(service) }
      result = @results[service.id]
      return { "status" => "pending" }.merge(head) unless result

      summary = result["summary"] || {}
      passed = summary["passed"].to_i
      failed = summary["failed"].to_i
      { "status" => "checked" }.merge(head).merge(
        "mode" => result["mode"] || mode,
        "test_instance" => result["test_instance"]&.slice("software", "version", "release"),
        "summary_text" => summary["text"], "passed" => passed, "total" => passed + failed, "failed" => failed,
        "warnings" => summary["warnings"].to_i, "proposed_failed" => summary.dig("proposed_not_counted", "failed").to_i,
        "checked_at" => result["run_at"].to_s[0, 10]
      ).compact
    end
  end
end
