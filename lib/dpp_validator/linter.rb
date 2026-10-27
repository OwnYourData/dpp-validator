require "cgi"

module DppValidator
  # Checks the example passports of a service entry (example_passports) with
  # the API of dpplint: GET <dpplint>/api/v1/validate/<product identifier>.
  # Requests go one after the other, with the User-Agent of dpp-validator and
  # a timeout long enough for dpplint to fetch and check the passport.
  #
  # dpplint counts like dpp-validator ("Results" in CRITERIA-FORMAT.md):
  # summary.passed are the active criteria with result passed or warning,
  # summary.failed those with result failed, summary.warnings how many of the
  # passed ones have a warning. total is passed + failed; skipped criteria do
  # not count.
  class Linter
    DEFAULT_URL = "https://dpplint.ownyourdata.eu".freeze

    def initialize(base_url: DEFAULT_URL, config: Config.new(read_timeout: 120), client: nil, now: Time.now.utc)
      @base_url = base_url.sub(%r{/+\z}, "")
      @client = client || Transport::Client.new(config)
      @now = now
    end

    # Result for all example passports of the service (hash, see README "Linter result").
    def run(service)
      {
        "service_id" => service.id,
        "checked_at" => @now.utc.iso8601,
        "dpplint" => @base_url,
        "passports" => service.example_passports.map { |p| check(p["product_id"], p["label"]) }
      }
    end

    def check(product_id, label)
      head = { "product_id" => product_id, "label" => label, "lint_url" => lint_url(product_id) }
      response = @client.request("#{@base_url}/api/v1/validate/#{product_id}", headers: { "Accept" => "application/json" })
      return head.merge("status" => "error", "error" => "dpplint: #{response.describe}") unless response.complete? && response.status == 200

      body = JSON.parse(response.body)
      summary = body["summary"] || {}
      head.merge(
        "status" => "checked",
        "dpp_criteria" => body["dpp-criteria"],
        "summary" => {
          "text" => summary["text"], "passed" => summary["passed"].to_i, "failed" => summary["failed"].to_i,
          "total" => summary["passed"].to_i + summary["failed"].to_i, "warnings" => summary["warnings"].to_i,
          "skipped" => summary["skipped"].to_i, "proposed_failed" => summary.dig("proposed_not_counted", "failed").to_i
        },
        "criteria" => Array(body["criteria"]).map do |c|
          c.slice("id", "title", "status", "result", "reason_code", "description_url")
        end
      )
    rescue JSON::ParserError => e
      head.merge("status" => "error", "error" => "dpplint answered with invalid JSON: #{e.message}")
    rescue URI::InvalidURIError => e
      head.merge("status" => "error", "error" => "product identifier cannot be sent to dpplint: #{e.message}")
    end

    # The summary of one passport counted from its criteria, as dpplint counts
    # (used when dpp-validator rates a criterion itself, see HistoryRating).
    def self.summary_of(criteria)
      active = criteria.select { |c| c["status"] == "active" }
      counted = active.select { |c| %w[passed warning failed].include?(c["result"]) }
      passed = counted.count { |c| c["result"] != "failed" }
      {
        "text" => "#{passed} of #{counted.size} automated checks passed", "passed" => passed, "failed" => counted.size - passed,
        "total" => counted.size, "warnings" => active.count { |c| c["result"] == "warning" },
        "skipped" => active.count { |c| c["result"] == "skipped" },
        "proposed_failed" => criteria.count { |c| c["status"] == "proposed" && c["result"] == "failed" }
      }
    end

    # Page of dpplint that shows the check of this passport to people.
    def lint_url(product_id) = self.class.lint_url(product_id, @base_url)

    def self.lint_url(product_id, base_url = DEFAULT_URL) = "#{base_url.sub(%r{/+\z}, '')}/?productId=#{CGI.escape(product_id)}"
  end
end
