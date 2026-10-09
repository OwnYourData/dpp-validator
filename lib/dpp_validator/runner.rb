module DppValidator
  # Runs the criteria of a dpp-criteria checkout against one service entry.
  #
  # In scope are criteria with target service or operator; deprecated
  # criteria are left out. Passport criteria (target passport) are checked by
  # dpplint and listed under not_run in this version.
  #
  # Per criterion, in this order (reason_code in brackets, see "Results" in
  # CRITERIA-FORMAT.md):
  # 1. the file does not match the criterion schema -> skipped (not_evaluated);
  # 2. a feature in requires_features is not declared by the service ->
  #    skipped (not_implemented if the service lists it under
  #    not_implemented, otherwise not_applicable);
  # 3. method self-declared -> skipped (not_evaluated; declarations are not
  #    evaluated yet and are never reported as passed);
  # 4. method automated-auth -> skipped (needs_credentials);
  # 5. the check type is not implemented -> skipped (not_evaluated);
  # 6. read-only run and a step with a method other than GET, HEAD or
  #    OPTIONS -> skipped (not_sent), before any request of the criterion;
  # 7. otherwise the check type decides (Checks).
  # An error in the runner gives skipped (not_evaluated).
  class Runner
    IN_SCOPE = %w[service operator].freeze

    def initialize(repository:, service:, config: Config.new, client: nil, now: Time.now.utc, random_id: nil)
      @repository = repository
      @service = service
      @config = config
      @client = client || Transport::Client.new(config)
      @now = now
      @placeholders = Placeholders.for(service, now: now, random_id: random_id)
    end

    def run
      context = Checks::Context.new(service: @service, placeholders: @placeholders, client: @client, config: @config)
      current = @repository.criteria.reject { |c| c["status"] == "deprecated" }
      results = current.select { |c| IN_SCOPE.include?(c["target"]) }.sort_by(&:id).map { |c| evaluate(c, context) }
      not_run = current.reject { |c| IN_SCOPE.include?(c["target"]) }.sort_by(&:id).map do |c|
        { "id" => c.id, "target" => c["target"], "reason" => "passport criteria are checked by dpplint, not connected in this version" }
      end
      Report.new(service: @service, run_at: @now, criteria_commit: @repository.commit, results: results, not_run: not_run,
                 read_only: @config.read_only)
    end

    def evaluate(criterion, context)
      check = criterion["check"] || {}
      head = {
        "id" => criterion.id, "version" => criterion["version"], "status" => criterion["status"],
        "title" => criterion["title"], "description_url" => @repository.description_url(criterion.id),
        "level" => criterion["level"], "target" => criterion["target"],
        "method" => criterion["method"], "check_type" => check["type"]
      }.compact
      outcome = decide(criterion, check, context)
      head.merge(
        "result" => outcome.result,
        "reason" => outcome.reason,
        "reason_code" => outcome.reason_code,
        "messages" => outcome.messages.map { |m| { "severity" => m[:severity], "message" => m[:message] } },
        "details" => outcome.details
      ).compact
    end

    private

    def decide(criterion, check, context)
      if criterion.schema_errors.any?
        return Checks::Outcome.skipped("#{criterion.file} does not match schema/criterion.schema.json: #{criterion.schema_errors.join('; ')}",
                                       code: "not_evaluated")
      end

      missing = Array(criterion["requires_features"]) - @service.features
      if missing.any?
        planned = missing & @service.not_implemented
        return Checks::Outcome.skipped("the service lists #{planned.join(', ')} as not implemented", code: "not_implemented") if planned.any?

        return Checks::Outcome.skipped("the service does not declare #{missing.join(', ')}", code: "not_applicable")
      end

      case criterion["method"]
      when "self-declared"
        return Checks::Outcome.skipped("self-declared criterion: declarations are not evaluated in this version and never count as passed",
                                       code: "not_evaluated")
      when "automated-auth"
        return Checks::Outcome.skipped("needs test credentials of the operator (automated-auth), not supported in this version",
                                       code: "needs_credentials")
      end

      klass = Checks.for(check["type"])
      return Checks::Outcome.skipped("check type #{check['type']} is not implemented in this version", code: "not_evaluated") unless klass

      if @config.read_only && (unsafe = unsafe_steps(check)).any?
        return Checks::Outcome.skipped("read-only run: not sent, the criterion needs #{unsafe.join(', ')}", code: "not_sent")
      end

      klass.new(check, context).call
    rescue StandardError => e
      Checks::Outcome.skipped("runner error: #{e.class}: #{e.message}", code: "not_evaluated")
    end

    # Steps of an http check whose method a read-only run does not send.
    def unsafe_steps(check)
      Array(check["steps"]).each_with_index.filter_map do |step, index|
        method = step.dig("request", "method").to_s.upcase
        "step #{index + 1} #{method} #{step.dig('request', 'path')}" unless Checks::SAFE_METHODS.include?(method)
      end
    end
  end
end
