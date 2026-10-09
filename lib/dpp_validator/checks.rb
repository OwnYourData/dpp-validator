module DppValidator
  # Check types the runner implements. Each check type is a class with
  #   new(check, context) and #call -> Outcome
  # Phase 2 registers further types here (e.g. passport criteria through
  # dpplint, history-based ratings) without changing the runner.
  module Checks
    # result: "passed" | "failed" | "warning" | "skipped"
    # reason: why a criterion was skipped
    # reason_code: one of REASON_CODES for a skipped criterion ("Results" in
    #   CRITERIA-FORMAT.md)
    # messages: failures and warnings ({ severity:, message: })
    # details: observations that explain the result (informational)
    REASON_CODES = %w[not_applicable not_implemented no_evidence needs_credentials not_sent unreachable not_evaluated].freeze

    Outcome = Struct.new(:result, :reason, :reason_code, :messages, :details, keyword_init: true) do
      def self.skipped(reason, code:, details: [], messages: [])
        raise ArgumentError, "unknown reason_code #{code}" unless REASON_CODES.include?(code)

        new(result: "skipped", reason: reason, reason_code: code, messages: messages, details: details)
      end

      def self.from(messages, details: []) = new(result: Messages.result_for(messages), messages: messages, details: details)
    end

    # service: Service; placeholders: Placeholders; client: Transport::Client
    Context = Struct.new(:service, :placeholders, :client, :config, keyword_init: true)

    # Request methods a read-only run sends ("Read-only run" in CRITERIA-FORMAT.md).
    SAFE_METHODS = %w[GET HEAD OPTIONS].freeze

    @registry = {}

    def self.register(type, klass) = @registry[type] = klass
    def self.for(type) = @registry[type]
    def self.types = @registry.keys
  end
end
