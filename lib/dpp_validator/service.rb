module DppValidator
  # A DPP service in the list (services/<id>.yaml of dpp-criteria).
  #
  # entry.source says who maintains the entry: "operator" (pull request by the
  # operator or with linked consent; checked in full every day) or "research"
  # (from the maintainers' own research; checked read-only at most once a
  # week, or not at all). check.mode is full-daily, read-only-weekly or none
  # (with check.reason).
  class Service
    CADENCE = { "full-daily" => "daily", "read-only-weekly" => "weekly" }.freeze

    attr_reader :data

    def initialize(data)
      @data = data
    end

    def id = data["id"]
    def name = data["name"]
    def url = data["url"]
    def api_base = data["api_base"]
    def features = Array(data["features"])
    def not_implemented = Array(data["not_implemented"])
    def test_data = data["test_data"] || {}
    def credentials = data["credentials"] || "none"
    def source = data.dig("entry", "source") || "operator"
    def as_of = data.dig("entry", "as_of")&.to_s
    def research? = source == "research"
    def check_mode = data.dig("check", "mode") || "full-daily"
    def check_reason = data.dig("check", "reason")
    def checked? = check_mode != "none"
    def read_only? = check_mode == "read-only-weekly"
    def notes = data["notes"]
    def licence = data["licence"] || {}
    def example_passports = Array(data["example_passports"])

    # "daily" for operator entries, "weekly" for research entries: when the
    # service and its example passports are checked.
    def cadence = research? ? "weekly" : "daily"

    def to_h
      { "id" => id, "name" => name, "url" => url, "operator" => data.dig("operator", "name"), "operator_url" => data.dig("operator", "url"),
        "country" => data.dig("operator", "country"), "entry" => { "source" => source, "as_of" => as_of },
        "contact" => data["contact"], "api_base" => api_base, "features" => features, "not_implemented" => not_implemented,
        "check" => { "mode" => check_mode, "reason" => check_reason }.compact, "listed_since" => data["listed_since"].to_s }.compact
    end
  end
end
