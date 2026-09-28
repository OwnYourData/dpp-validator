module DppValidator
  # Placeholders of CRITERIA-FORMAT.md ("Placeholders in checks"): {base},
  # {dppId}, {productId}, {elementIdPath}, {randomId}, {now}. Values come from
  # the service entry (api_base, test_data) and from the run ({randomId} and
  # {now} are fixed once per run).
  #
  # In the path of an http request, placeholder values are percent-encoded:
  # every octet outside the unreserved characters of RFC 3986 (A-Z a-z 0-9
  # - . _ ~) is encoded, so that a value stays one path segment or one query
  # value. Text around the placeholders is left as written in the criterion
  # (e.g. %24%5B in DPP-API-021). Everywhere else (headers, bodies, expected
  # values, JSONPath) values are inserted as they are.
  #
  # Only the names above are placeholders; other text in braces, such as the
  # body "{not json" of DPP-API-007, stays unchanged.
  class Placeholders
    NAMES = %w[base dppId productId elementIdPath randomId now].freeze
    PATTERN = /\{(#{NAMES.join('|')})\}/
    UNRESERVED = /[^A-Za-z0-9\-._~]/

    class Missing < DppValidator::Error; end

    attr_reader :values

    def initialize(values)
      @values = values.transform_keys(&:to_s).reject { |_, v| v.nil? || v.to_s.empty? }
    end

    def self.for(service, now: Time.now.utc, random_id: nil)
      data = service.test_data
      new(
        "base" => service.api_base,
        "dppId" => data["dppId"],
        "productId" => data["productId"],
        "elementIdPath" => data["elementIdPath"],
        "randomId" => random_id || "dpp-validator-#{SecureRandom.hex(16)}",
        "now" => now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      )
    end

    # Names used in any string of the (nested) value.
    def self.used(value)
      case value
      when String then value.scan(PATTERN).flatten.uniq
      when Array then value.flat_map { |v| used(v) }.uniq
      when Hash then value.flat_map { |k, v| used(k) + used(v) }.uniq
      else []
      end
    end

    # Names used in the value that have no value in this run.
    def missing(value) = self.class.used(value).reject { |name| @values.key?(name) }

    # Substitutes in strings, arrays and objects (keys and values).
    def expand(value)
      case value
      when String then value.gsub(PATTERN) { fetch(Regexp.last_match(1)) }
      when Array then value.map { |v| expand(v) }
      when Hash then value.to_h { |k, v| [expand(k), expand(v)] }
      else value
      end
    end

    # Substitutes in a request path, percent-encoding the values.
    def expand_path(path)
      path.to_s.gsub(PATTERN) { self.class.percent_encode(fetch(Regexp.last_match(1))) }
    end

    def self.percent_encode(value)
      value.to_s.b.gsub(UNRESERVED) { |c| format("%%%02X", c.ord) }.force_encoding(Encoding::UTF_8)
    end

    private

    def fetch(name)
      @values.fetch(name) { raise Missing, "no value for {#{name}} in this run (test_data of the service)" }
    end
  end
end
