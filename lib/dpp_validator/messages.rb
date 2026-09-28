module DppValidator
  # Messages of a check are { severity: "error" | "warning", message: }.
  # The result of a criterion follows "Results" in CRITERIA-FORMAT.md:
  # failed if a check with severity error fails, otherwise warning if a check
  # with severity warning fails, otherwise passed.
  module Messages
    SEVERITIES = %w[error warning].freeze

    module_function

    def error(message) = { severity: "error", message: message }
    def warning(message) = { severity: "warning", message: message }

    # severity of an assertion or step: "warning" or "error" (the default).
    def severity(value) = value.to_s == "warning" ? "warning" : "error"

    def with_severity(message, severity) = { severity: severity, message: message }

    # Turns every message into a warning (severity: warning on a step).
    def downgrade(messages) = messages.map { |m| m.merge(severity: "warning") }

    def prefix(messages, label) = messages.map { |m| m.merge(message: "#{label}: #{m[:message]}") }

    def result_for(messages)
      if messages.any? { |m| m[:severity] == "error" } then "failed"
      elsif messages.any? then "warning"
      else "passed"
      end
    end
  end
end
