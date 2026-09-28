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
      { "id" => id, "name" => name, "operator" => data.dig("operator", "name"), "api_base" => api_base, "features" => features }
    end
  end
end
