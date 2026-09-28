module DppValidator
  module Transport
    # Outcome of one request. Either `status` is set (a response came back)
    # or `error` is set with an `error_kind`:
    #
    # - :dns, :connect, :connect_timeout: no TCP connection (service not reachable)
    # - :tls: TLS handshake aborted (alert, reset or close during the handshake)
    # - :alpn: TLS handshake aborted with the ALPN alert no_application_protocol
    # - :certificate: certificate verification failed
    # - :alpn_not_selected: HTTP/2 was requested, the server did not select h2
    # - :timeout: no response within the read timeout
    # - :closed: connection closed without a (complete) response
    # - :protocol: the response could not be parsed (HTTP/1.x or HTTP/2 error)
    #
    # A response whose body was cut off keeps its status and also has an
    # error (:timeout or :closed).
    UNREACHABLE = %i[dns connect connect_timeout].freeze

    Response = Struct.new(:status, :headers, :body, :protocol, :tls_version, :alpn, :error, :error_kind,
                          keyword_init: true) do
      def self.failure(kind, message, **extra) = new(error: message, error_kind: kind, headers: {}, **extra)

      def headers = self[:headers] || {}
      def status? = !status.nil?
      def complete? = status? && error.nil?
      def unreachable? = UNREACHABLE.include?(error_kind)

      # 2xx or 3xx: a successful response in the sense of http_versions.
      def success_or_redirect? = status? && status.between?(200, 399)

      # Combined value of all fields with this name (RFC 9110 5.3).
      def header(name) = HeaderAssertion.field(headers, name)

      # Media type without parameters, lower case.
      def media_type = header("content-type").to_s.split(";").first.to_s.strip.downcase

      def describe
        return "no response (#{error})" unless status?

        text = "HTTP #{status}"
        text += " over #{protocol}" if protocol
        text += " (#{error})" if error
        text
      end
    end
  end
end
