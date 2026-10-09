module DppValidator
  module Checks
    # Check type http ("Check types" in CRITERIA-FORMAT.md).
    #
    # Before any request: every placeholder used must have a value, and every
    # regular expression (`matches` in JSON and header assertions,
    # `base_matches`, match()/search() in JSONPath) and every JSONPath must be
    # usable; otherwise the criterion is skipped with the reason ("Results").
    #
    # `base_matches` is searched in the API base (ECMA-262, EcmaRegexp).
    # The steps run in order, each as one request relative to {base} with the
    # runner's default negotiation (HTTP/2 or HTTP/1.1 via ALPN), certificate
    # verification on, no redirects followed. Per step:
    #
    # - status in `skip_if_status` -> the criterion is skipped, unless an
    #   earlier step has failed: then it fails; later steps are not sent;
    # - status in `warn_if_status` -> a warning, `expect` is not evaluated;
    # - otherwise `expect` (Expectation);
    # - `severity: warning` on the step turns its failures into warnings.
    #
    # A request that cannot reach the service at all (no TCP connection) skips
    # the criterion: availability is rated separately (DPP-ID-002, history).
    # Requests with `auth: token` need credentials, which this version does
    # not support; such a criterion is skipped.
    class HttpCheck
      DEFAULT_CONTENT_TYPE = "application/json".freeze

      def initialize(check, context)
        @check = check
        @context = context
        @placeholders = context.placeholders
      end

      def call
        reason, code = problem
        return Outcome.skipped(reason, code: code) if reason

        messages = []
        details = []
        messages.concat(base_messages)
        responses = []
        steps.each_with_index do |step, index|
          label = "step #{index + 1} (#{step['request']['method']} #{step['request']['path']})"
          response = perform(step)
          responses << response
          details << "#{label}: #{response.describe}"
          return Outcome.skipped("#{label}: service not reachable (#{response.error})", code: "unreachable", details: details) if response.unreachable?

          step_messages = evaluate(step, response, responses[0...index])
          if step_messages == :skip
            skip_text = "#{label}: HTTP status #{response.status} is listed in skip_if_status"
            return Outcome.skipped(skip_text, code: "not_applicable", details: details) if messages.none? { |m| m[:severity] == "error" }

            # An earlier step has failed: that failure stands (CRITERIA-FORMAT.md,
            # "Requests and steps"); the remaining steps are not sent.
            return Outcome.from(messages, details: details + ["#{skip_text}; an earlier step failed, so the criterion fails"])
          end

          step_messages = Messages.downgrade(step_messages) if step["severity"] == "warning"
          messages.concat(Messages.prefix(step_messages, label))
        end
        Outcome.from(messages, details: details)
      end

      private

      def steps = Array(@check["steps"])

      # [reason, reason_code] if the criterion cannot be evaluated, otherwise nil.
      def problem
        missing = @placeholders.missing(steps.map { |s| s["request"] } + steps.map { |s| s["expect"] })
        return ["no value for #{missing.map { |n| "{#{n}}" }.join(', ')} in the test_data of the service", "not_evaluated"] if missing.any?
        if steps.any? { |s| s.dig("request", "auth") == "token" }
          return ["a step needs credentials (auth: token), which this version does not support", "needs_credentials"]
        end
        if @check.key?("base_matches") && (reason = EcmaRegexp.problem(@check["base_matches"]))
          return ["regular expression #{@check['base_matches'].to_s.inspect} of base_matches #{reason}", "not_evaluated"]
        end

        steps.each_with_index do |step, index|
          reason = Expectation.new(step["expect"], @placeholders).problem
          return ["step #{index + 1}: #{reason}", "not_evaluated"] if reason
        end
        nil
      end

      def base_messages
        return [] unless @check.key?("base_matches")

        base = @context.service.api_base
        return [] if EcmaRegexp.search?(@check["base_matches"], base)

        [Messages.error("the API base #{base} does not match /#{@check['base_matches']}/")]
      end

      def perform(step)
        request = step["request"]
        headers = @placeholders.expand(request["headers"] || {})
        body = request.key?("body") ? body_for(request["body"]) : nil
        if body && !request["body"].is_a?(String) && headers.keys.none? { |k| k.casecmp?("content-type") }
          headers["Content-Type"] = DEFAULT_CONTENT_TYPE
        end
        url = @context.service.api_base.sub(%r{/+\z}, "") + @placeholders.expand_path(request["path"])
        @context.client.request(url, method: request["method"], headers: headers, body: body)
      end

      # A string body is sent as is, any other value as JSON.
      def body_for(body)
        expanded = @placeholders.expand(body)
        expanded.is_a?(String) ? expanded : JSON.generate(expanded)
      end

      def evaluate(step, response, earlier)
        severity = Messages.severity(step["severity"])
        return [Messages.with_severity("no response: #{response.error}", severity)] unless response.status?
        return :skip if Array(step["skip_if_status"]).include?(response.status)
        if Array(step["warn_if_status"]).include?(response.status)
          return [Messages.warning("HTTP status #{response.status} is listed in warn_if_status")]
        end

        messages = Expectation.new(step["expect"], @placeholders).messages(response, earlier: earlier)
        messages << Messages.error("incomplete response: #{response.error}") if response.error && messages.empty?
        messages
      end
    end

    register("http", HttpCheck)
  end
end
