module DppValidator
  # A DPP service in the list (services/<id>.yaml of dpp-criteria).
  #
  # entry.source says who maintains the entry: "operator" (pull request by the
  # operator or with linked consent; checked in full every day) or "research"
  # (from the maintainers' own research; checked read-only at most once a
  # week, in full once a week on our own test instance, or not at all).
  # check.mode is full-daily, read-only-weekly, test-instance-weekly or none
  # (with check.reason). An entry checked on a test instance has no api_base
  # and no test_data of its own: the running test instance provides them
  # (on_test_instance).
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
    def test_instance? = check_mode == "test-instance-weekly"
    def test_instance = data["test_instance"] || {}
    def notes = data["notes"]
    def licence = data["licence"] || {}
    def example_passports = Array(data["example_passports"])

    # Self-declarations of the operator (declarations): criterion, statement
    # and evidence URL, as the entry gives them. Entries from our research have
    # none.
    def declarations = Array(data["declarations"]).select { |d| d.is_a?(Hash) }

    # "daily" for operator entries, "weekly" for research entries: when the
    # service and its example passports are checked.
    def cadence = research? ? "weekly" : "daily"

    # Criteria listed under test_instance.not_applicable: { id => reason }.
    def not_applicable_on_test_instance
      Array(test_instance["not_applicable"]).to_h { |n| [n["criterion"], n["reason"].to_s.strip] }
    end

    # The entry with the API base and the test passport of a running test
    # instance (the info file written when the instance was started).
    def on_test_instance(info)
      Service.new(data.merge("api_base" => info["api_base"], "test_data" => info["test_data"]))
    end

    def to_h
      { "id" => id, "name" => name, "url" => url, "operator" => data.dig("operator", "name"), "operator_url" => data.dig("operator", "url"),
        "country" => data.dig("operator", "country"), "entry" => { "source" => source, "as_of" => as_of },
        "contact" => data["contact"], "api_base" => api_base, "features" => features, "not_implemented" => not_implemented,
        "check" => { "mode" => check_mode, "reason" => check_reason }.compact,
        "test_instance" => (test_instance.slice("setup", "configuration") if test_instance?),
        "listed_since" => data["listed_since"].to_s }.compact
    end
  end
end
