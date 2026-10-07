module DppValidator
  # A JSON assertion of CRITERIA-FORMAT.md ("Check types", http): an RFC 9535
  # JSONPath `path` and the operations `exists`, `equals`, `in`, `matches`,
  # each optional, with an optional `severity: warning`.
  #
  # The path selects a node list. `exists` compares whether it is non-empty.
  # `equals`, `in` and `matches` hold if at least one selected value does
  # (for singular paths, the one value). `matches` is an ECMA-262 regular
  # expression searched in the value (EcmaRegexp); it holds only for JSON
  # strings, other values are never converted to text ("Regular
  # expressions"). JSON values are compared by value: 1 equals 1.0, objects
  # regardless of member order.
  class JsonAssertion
    OPERATIONS = %w[exists equals in matches].freeze

    # problem: a reason found before construction (e.g. a placeholder outside
    # a string literal of the JSONPath), reported by #problem.
    def initialize(assertion, problem: nil)
      @assertion = assertion
      @path = assertion["path"].to_s
      @known_problem = problem
    end

    def severity = Messages.severity(@assertion["severity"])

    # nil if the assertion can be evaluated, otherwise the reason (invalid
    # JSONPath, unusable I-Regexp in match()/search(), unusable ECMA-262
    # pattern in `matches`).
    def problem
      return @known_problem if @known_problem

      reason = JsonPath.problem(@path)
      return reason if reason
      return nil unless @assertion.key?("matches")

      reason = EcmaRegexp.problem(@assertion["matches"])
      reason && "regular expression #{@assertion['matches'].to_s.inspect} for #{@path} #{reason}"
    end

    # Messages for the operations that do not hold on the JSON document.
    def messages(document)
      values = JsonPath.select(@path, document)
      OPERATIONS.select { |op| @assertion.key?(op) }.filter_map do |op|
        text = failure(op, @assertion[op], values)
        text && Messages.with_severity(text, severity)
      end
    end

    private

    def failure(op, expected, values)
      if op == "exists"
        return nil if expected == !values.empty?

        return expected ? "#{@path} selects nothing, expected a value" : "#{@path} selects #{show(values)}, expected nothing"
      end
      return "#{@path} selects nothing, expected #{describe(op, expected)}" if values.empty?

      holds = case op
              when "equals" then values.any? { |v| v == expected }
              when "in" then values.any? { |v| Array(expected).any? { |e| v == e } }
              when "matches" then values.any? { |v| v.is_a?(String) && EcmaRegexp.search?(expected, v) }
              end
      holds ? nil : "#{@path} is #{show(values)}, expected #{describe(op, expected)}"
    end

    def describe(op, expected)
      case op
      when "equals" then "#{JSON.generate(expected)}"
      when "in" then "one of #{JSON.generate(expected)}"
      when "matches" then "a string matching /#{expected}/"
      end
    end

    def show(values)
      text = values.size == 1 ? JSON.generate(values.first) : JSON.generate(values)
      text.size > 200 ? "#{text[0, 200]}..." : text
    end
  end
end
