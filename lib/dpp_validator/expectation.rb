module DppValidator
  # Evaluates an `expect` block on one response, following "Order of
  # evaluation within a request" in CRITERIA-FORMAT.md:
  #
  # 1. `status` and `content_type`. content_type compares the media type
  #    without parameters, case-insensitively. For a JSON media type
  #    (application/json or a +json type) the body must also parse as JSON;
  #    this belongs to the content_type check. In http any JSON value is
  #    accepted; `single_object: true` (resolve) requires one JSON object.
  # 2. Only if both hold: `headers` (HeaderAssertion), `json` (JsonAssertion)
  #    and `body_equals_step`. Otherwise these give no message of their own.
  #
  # Written for the http check type and usable for resolve requests.
  class Expectation
    def initialize(expect, placeholders, single_object: false)
      @expect = expect || {}
      @placeholders = placeholders
      @single_object = single_object
    end

    # Placeholders are substituted in `equals` and `in` as they are and in
    # the JSONPath `path` escaped inside its string literals; a placeholder
    # outside a string literal makes the assertion unusable. `matches` is a
    # regular expression and stays as written.
    def json_assertions
      Array(@expect["json"]).map do |a|
        expanded = a.dup
        %w[equals in].each { |k| expanded[k] = @placeholders.expand(a[k]) if a.key?(k) }
        begin
          expanded["path"] = @placeholders.expand_json_path(a["path"])
          JsonAssertion.new(expanded)
        rescue Placeholders::Unusable => e
          JsonAssertion.new(expanded, problem: e.message)
        end
      end
    end

    # nil if every pattern and JSONPath can be evaluated, otherwise the reason.
    def problem
      reason = HeaderAssertion.problem(@expect["headers"])
      return reason if reason

      json_assertions.each do |assertion|
        reason = assertion.problem
        return reason if reason
      end
      nil
    end

    # earlier: responses of the earlier steps (index 0 = step 1), for body_equals_step.
    def messages(response, earlier: [])
      first = status_and_content_type(response)
      return first if first.any?

      header_messages(response) + json_messages(response) + body_messages(response, earlier)
    end

    private

    def status_and_content_type(response)
      out = []
      if (statuses = @expect["status"]) && !statuses.include?(response.status)
        out << Messages.error("HTTP status is #{response.status}, expected #{statuses.join(' or ')}")
      end
      return out unless (type = @expect["content_type"])

      expected = type.to_s.split(";").first.to_s.strip.downcase
      if response.media_type != expected
        actual = response.header("content-type")
        out << Messages.error("Content-Type is #{actual.nil? || actual.empty? ? 'missing' : actual}, expected #{type}")
      elsif json_media_type?(expected)
        document = parse_json(response.body)
        if document == :invalid then out << Messages.error("the body is not valid JSON")
        elsif @single_object && !document.is_a?(Hash) then out << Messages.error("the body is not a single JSON object")
        end
      end
      out
    end

    def header_messages(response)
      Array(@expect["headers"]).flat_map do |assertion|
        severity = Messages.severity(assertion["severity"])
        HeaderAssertion.new(assertion).failures(response.headers).map { |m| Messages.with_severity(m, severity) }
      end
    end

    def json_messages(response)
      assertions = json_assertions
      return [] if assertions.empty?

      document = parse_json(response.body)
      return [Messages.error("the body is not valid JSON, so the JSON assertions cannot hold")] if document == :invalid

      assertions.flat_map { |assertion| assertion.messages(document) }
    end

    def body_messages(response, earlier)
      step = @expect["body_equals_step"]
      return [] unless step

      other = earlier[step - 1]
      return [Messages.error("step #{step} has no response to compare the body with")] unless other&.status?
      return [] if other.body.b == response.body.b

      [Messages.error("the body differs from the body of step #{step} (#{response.body.bytesize} vs. #{other.body.bytesize} bytes)")]
    end

    def json_media_type?(type) = type == "application/json" || type.end_with?("+json")

    def parse_json(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError, EncodingError
      :invalid
    end
  end
end
