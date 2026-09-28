module DppValidator
  # Check types the runner implements. Each check type is a class with
  #   new(check, context) and #call -> Outcome
  # Phase 2 registers further types here (e.g. passport criteria through
  # dpplint, history-based ratings) without changing the runner.
  module Checks
    # result: "passed" | "failed" | "warning" | "skipped"
    # reason: why a criterion was skipped
    # messages: failures and warnings ({ severity:, message: })
    # details: observations that explain the result (informational)
    Outcome = Struct.new(:result, :reason, :messages, :details, keyword_init: true) do
      def self.skipped(reason, details: []) = new(result: "skipped", reason: reason, messages: [], details: details)
      def self.from(messages, details: []) = new(result: Messages.result_for(messages), messages: messages, details: details)
    end

    # service: Service; placeholders: Placeholders; client: Transport::Client
    Context = Struct.new(:service, :placeholders, :client, :config, keyword_init: true)

    @registry = {}

    def self.register(type, klass) = @registry[type] = klass
    def self.for(type) = @registry[type]
    def self.types = @registry.keys
  end
end
