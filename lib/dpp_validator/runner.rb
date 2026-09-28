module DppValidator
  # Runs the criteria of a dpp-criteria checkout against one service entry.
  #
  # In scope are criteria with target service or operator; deprecated
  # criteria are left out. Passport criteria (target passport) are checked by
  # dpplint and listed under not_run in this version.
  #
  # Per criterion, in this order:
  # 1. the file does not match the criterion schema -> skipped;
  # 2. a feature in requires_features is not declared by the service -> skipped;
  # 3. method self-declared -> skipped (declarations are not evaluated yet;
  #    they are never reported as passed);
  # 4. method automated-auth -> skipped (needs test credentials);
  # 5. the check type is not implemented -> skipped;
  # 6. otherwise the check type decides (Checks).
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
      Report.new(service: @service, run_at: @now, criteria_commit: @repository.commit, results: results, not_run: not_run)
    end

    def evaluate(criterion, context)
      check = criterion["check"] || {}
      head = {
        "id" => criterion.id, "version" => criterion["version"], "status" => criterion["status"],
        "title" => criterion["title"], "level" => criterion["level"], "target" => criterion["target"],
        "method" => criterion["method"], "check_type" => check["type"]
      }
      outcome = decide(criterion, check, context)
      head.merge(
        "result" => outcome.result,
        "reason" => outcome.reason,
        "messages" => outcome.messages.map { |m| { "severity" => m[:severity], "message" => m[:message] } },
        "details" => outcome.details
      ).compact
    end

    private

    def decide(criterion, check, context)
      if criterion.schema_errors.any?
        return Checks::Outcome.skipped("#{criterion.file} does not match schema/criterion.schema.json: #{criterion.schema_errors.join('; ')}")
      end

      missing = Array(criterion["requires_features"]) - @service.features
      return Checks::Outcome.skipped("the service does not declare #{missing.join(', ')}") if missing.any?

      case criterion["method"]
      when "self-declared"
        return Checks::Outcome.skipped("self-declared criterion: declarations are not evaluated in this version and never count as passed")
      when "automated-auth"
        return Checks::Outcome.skipped("needs test credentials of the operator (automated-auth), not supported in this version")
      end

      klass = Checks.for(check["type"])
      return Checks::Outcome.skipped("check type #{check['type']} is not implemented in this version") unless klass

      klass.new(check, context).call
    rescue StandardError => e
      Checks::Outcome.skipped("runner error: #{e.class}: #{e.message}")
    end
  end
end
