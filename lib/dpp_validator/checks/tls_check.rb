module DppValidator
  module Checks
    # Check type tls ("Check types" in CRITERIA-FORMAT.md). All parts use the
    # host and HTTPS port of the API base.
    #
    # - valid_certificate: a handshake with certificate and host name
    #   verification against the trust store of the runner.
    # - https_redirect: GET http://<host>:80<base path>/dpps/{dppId}. Passes if
    #   the connection is refused or closed, the answer is a redirect to an
    #   https URL, or the status is 400 or higher (nothing served); fails on
    #   2xx or a redirect to a non-https URL.
    # - min_version: a handshake that also offers older versions (security
    #   level 0) must negotiate at least this version.
    # - reject_versions: a handshake forced to each version must fail. SSL 3.0
    #   is tested with a ClientHello of our own (Transport::Ssl3Probe), since
    #   OpenSSL 3 cannot offer it; it is accepted only if the server answers
    #   with an SSL 3.0 ServerHello. Any other version this runner cannot offer
    #   (Transport::TlsVersions.offer_problem) is not tested.
    # - recommend_versions: a handshake forced to each version should
    #   succeed; otherwise a warning.
    # - http_versions: GET {base}/dpps/{dppId}. First a reference request with
    #   the default negotiation; if it does not answer 2xx or 3xx, the
    #   http_versions parts are not tested. Each version in `reject` is then
    #   requested over TLS with ALPN offering only that version: rejected if
    #   the connection or handshake is aborted (also ALPN
    #   no_application_protocol), closed or timed out without a response, or
    #   the status is 400 or higher; a 2xx or 3xx answer fails. Each version
    #   in `require` must be selected in ALPN and answer 2xx or 3xx. HTTP/3
    #   (QUIC) is not tested by this runner.
    #
    # Certificate verification is off for all parts except valid_certificate,
    # so that protocol behaviour is judged separately from the certificate.
    #
    # The criterion fails if any part fails. Otherwise it is skipped if any
    # part could not be tested (never passed without that part), otherwise it
    # gives a warning if a recommendation is not met, otherwise it passes.
    # If the host does not accept TCP connections on the HTTPS port at all,
    # the criterion is skipped (availability is rated by DPP-ID-002).
    class TlsCheck
      Part = Struct.new(:state, :text) # state: :ok, :fail, :warn, :untested

      def initialize(check, context)
        @check = check
        @context = context
        @client = context.client
        @base = context.service.api_base.sub(%r{/+\z}, "")
      end

      def call
        uri = URI.parse(@base)
        return Outcome.from([Messages.error("the API base #{@base} does not use HTTPS")]) unless uri.scheme == "https"
        needs_dpp_id = @check.key?("http_versions") || @check["https_redirect"]
        if needs_dpp_id && @context.placeholders.missing("{dppId}").any?
          return Outcome.skipped("no value for {dppId} in the test_data of the service", code: "not_evaluated")
        end
        if (unreachable = @client.reachable(@base))
          return Outcome.skipped("service not reachable (#{unreachable.error})", code: "unreachable")
        end

        parts = []
        parts << certificate if @check["valid_certificate"]
        parts << redirect if @check["https_redirect"]
        parts << minimum(@check["min_version"]) if @check["min_version"]
        Array(@check["reject_versions"]).each { |v| parts << reject_tls(v) }
        Array(@check["recommend_versions"]).each { |v| parts << recommend_tls(v) }
        parts.concat(http_versions(@check["http_versions"])) if @check["http_versions"]
        combine(parts)
      end

      private

      def combine(parts)
        messages = parts.select { |p| p.state == :fail }.map { |p| Messages.error(p.text) } +
                   parts.select { |p| p.state == :warn }.map { |p| Messages.warning(p.text) }
        details = parts.select { |p| p.state == :ok }.map(&:text)
        untested = parts.select { |p| p.state == :untested }.map(&:text)
        if messages.none? { |m| m[:severity] == "error" } && untested.any?
          return Outcome.skipped(untested.join("; "), code: "not_evaluated", messages: messages, details: details)
        end

        Outcome.from(messages, details: details + untested)
      end

      def dpp_url = @base + "/dpps/" + Placeholders.percent_encode(@context.placeholders.values["dppId"])

      def certificate
        hs = @client.handshake_only(@base, verify: true)
        return Part.new(:ok, "certificate valid for #{URI.parse(@base).host}") if hs.ok?
        return Part.new(:fail, hs.error) if hs.error_kind == :certificate

        Part.new(:fail, "no verified TLS connection: #{hs.error}")
      end

      def redirect
        uri = URI.parse(dpp_url)
        uri.scheme = "http"
        uri.port = @context.config.http_port
        res = @client.request(uri.to_s)
        return Part.new(:ok, "plain HTTP on port #{uri.port} refused (#{res.error})") unless res.status?

        location = res.header("location").to_s
        if res.status.between?(300, 399)
          return Part.new(:ok, "plain HTTP redirected to #{location}") if location.start_with?("https://")

          return Part.new(:fail, "plain HTTP answered #{res.status} with a redirect to #{location.empty? ? 'nothing' : location}, not to HTTPS")
        end
        return Part.new(:ok, "plain HTTP refused with status #{res.status}") if res.status >= 400

        Part.new(:fail, "plain HTTP on port #{uri.port} answered #{res.status} instead of redirecting to HTTPS")
      end

      def minimum(version)
        hs = @client.handshake_only(@base)
        return Part.new(:fail, "no TLS handshake, also when older versions are offered: #{hs.error}") unless hs.ok?
        if Transport::TlsVersions.rank(hs.version) >= Transport::TlsVersions.rank(version)
          return Part.new(:ok, "negotiated #{Transport::TlsVersions.name(hs.version)} (at least #{Transport::TlsVersions.name(version)})")
        end

        Part.new(:fail, "negotiated #{Transport::TlsVersions.name(hs.version)}, expected at least #{Transport::TlsVersions.name(version)}")
      end

      def reject_tls(version)
        return reject_ssl3 if version == "ssl3"

        if (reason = Transport::TlsVersions.offer_problem(version))
          return Part.new(:untested, "#{Transport::TlsVersions.name(version)} not tested: #{reason}")
        end

        hs = @client.handshake_only(@base, tls_version: version)
        return Part.new(:fail, "#{Transport::TlsVersions.name(version)} accepted") if hs.ok?

        Part.new(:ok, "#{Transport::TlsVersions.name(version)} refused (#{hs.error})")
      end

      def reject_ssl3
        hs = @client.ssl3_hello(@base)
        return Part.new(:untested, "SSL 3.0 not tested: #{hs.error}") if Transport::UNREACHABLE.include?(hs.error_kind)
        return Part.new(:fail, "SSL 3.0 accepted (an SSL 3.0 ClientHello was answered with an SSL 3.0 ServerHello)") if hs.ok?

        Part.new(:ok, "SSL 3.0 refused (#{hs.error})")
      end

      def recommend_tls(version)
        if (reason = Transport::TlsVersions.offer_problem(version))
          return Part.new(:untested, "#{Transport::TlsVersions.name(version)} not tested: #{reason}")
        end

        hs = @client.handshake_only(@base, tls_version: version)
        return Part.new(:ok, "#{Transport::TlsVersions.name(version)} supported") if hs.ok?

        Part.new(:warn, "#{Transport::TlsVersions.name(version)} not supported (#{hs.error})")
      end

      def http_versions(spec)
        reference = @client.request(dpp_url, verify: false)
        unless reference.success_or_redirect?
          reason = "reference request GET {base}/dpps/{dppId} with default negotiation gave #{reference.describe}, not 2xx or 3xx"
          return (Array(spec["reject"]) + Array(spec["require"])).map { |v| Part.new(:untested, "HTTP/#{v} not tested: #{reason}") }
        end

        parts = [Part.new(:ok, "reference request: #{reference.describe}")]
        Array(spec["require"]).each { |v| parts << require_http(v) }
        Array(spec["reject"]).each { |v| parts << reject_http(v) }
        parts
      end

      def require_http(version)
        return Part.new(:untested, "HTTP/3 not tested: this runner does not speak QUIC") if version == "3"

        res = @client.request(dpp_url, http_version: version, verify: false)
        return Part.new(:ok, "HTTP/#{version}: #{res.describe}") if res.success_or_redirect? && res.error.nil?

        Part.new(:fail, "HTTP/#{version} not supported: #{res.describe}")
      end

      def reject_http(version)
        res = @client.request(dpp_url, http_version: version, verify: false)
        if res.status? && res.success_or_redirect?
          return Part.new(:fail, "HTTP/#{version} not rejected: answered #{res.status} (ALPN offered only #{Transport::Client::ALPN[version].first})")
        end

        how = res.status? ? "status #{res.status}" : res.error
        Part.new(:ok, "HTTP/#{version} rejected (#{how})")
      end
    end

    register("tls", TlsCheck)
  end
end
