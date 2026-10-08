module DppValidator
  # A listed DPP service (services/<id>.yaml of dpp-criteria).
  class Service
    attr_reader :data

    def initialize(data)
      @data = data
    end

    def id = data["id"]
    def name = data["name"]
    def api_base = data["api_base"]
    def features = Array(data["features"])
    def test_data = data["test_data"] || {}
    def credentials = data["credentials"] || "none"

    def to_h
      { "id" => id, "name" => name, "operator" => data.dig("operator", "name"), "operator_url" => data.dig("operator", "url"),
        "contact" => data["contact"], "api_base" => api_base, "features" => features, "listed_since" => data["listed_since"].to_s }
    end
  end
end
