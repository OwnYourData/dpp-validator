module DppValidator
  module Transport
    # Opens one connection per request (no reuse, no redirects followed) and
    # speaks the HTTP version given:
    #
    # - :default: ALPN offers h2 and http/1.1; HTTP/2 if the server selects
    #   h2, otherwise HTTP/1.1 (the runner's default negotiation);
    # - "2": ALPN offers only h2; if the server does not select it, the
    #   result is an :alpn_not_selected failure;
    # - "1.1" / "1.0": ALPN offers only http/1.1 or http/1.0 and the request
    #   is sent as HTTP/1.1 or HTTP/1.0, whatever the server selects (no
    #   upgrade to another version).
    #
    # `tls_version` forces one TLS version (see TlsVersions). `verify: false`
    # skips certificate verification; it is used where the protocol behaviour
    # of a service is tested and certificate validity is a separate check
    # (valid_certificate). Proxies are not used: the checks need a direct TLS
    # connection to the service.
    class Client
      ALPN = { default: %w[h2 http/1.1], "2" => %w[h2], "1.1" => %w[http/1.1], "1.0" => %w[http/1.0] }.freeze
      DEFAULT_HEADERS = { "User-Agent" => DppValidator::USER_AGENT, "Accept" => "*/*" }.freeze
      CONNECT_TIMEOUTS = [Errno::ETIMEDOUT, (IO::TimeoutError if defined?(IO::TimeoutError))].compact.freeze

      Handshake = Struct.new(:version, :alpn, :error, :error_kind, keyword_init: true) do
        def ok? = error.nil?
      end

      attr_reader :config

      def initialize(config = Config.new)
        @config = config
      end

      def request(url, method: "GET", headers: {}, body: nil, http_version: :default, tls_version: nil, verify: true)
        uri = URI.parse(url)
        headers = merge_headers(headers)
        deadline = IoDeadline.deadline(@config.read_timeout)
        return plain(uri, method, headers, body, deadline) if uri.scheme == "http"

        tcp = connect(uri.hostname, uri.port)
        return tcp if tcp.is_a?(Response)

        begin
          ssl = handshake(tcp, uri.hostname, alpn: ALPN.fetch(http_version), tls_version: tls_version, verify: verify)
          return ssl if ssl.is_a?(Response)

          selected = ssl.alpn_protocol
          info = { tls_version: TlsVersions.from_negotiated(ssl.ssl_version), alpn: selected }
          speak = http_version == :default ? (selected == "h2" ? "2" : "1.1") : http_version
          if speak == "2" && selected != "h2"
            return Response.failure(:alpn_not_selected, "the server did not select h2 in ALPN (selected: #{selected || 'none'})", **info)
          end

          res = send_request(ssl, speak, authority(uri), method, uri.request_uri, headers, body, deadline)
          info.each { |k, v| res[k] = v }
          res
        ensure
          tcp.close unless tcp.closed?
        end
      end

      # A TLS handshake without an HTTP request.
      def handshake_only(url, tls_version: nil, verify: false, alpn: nil)
        uri = URI.parse(url)
        tcp = connect(uri.hostname, uri.port)
        return Handshake.new(error: tcp.error, error_kind: tcp.error_kind) if tcp.is_a?(Response)

        begin
          ssl = handshake(tcp, uri.hostname, alpn: alpn, tls_version: tls_version, verify: verify, lenient: tls_version.nil?)
          return Handshake.new(error: ssl.error, error_kind: ssl.error_kind) if ssl.is_a?(Response)

          Handshake.new(version: TlsVersions.from_negotiated(ssl.ssl_version), alpn: ssl.alpn_protocol)
        ensure
          tcp.close unless tcp.closed?
        end
      end

      # SSL 3.0 test with a ClientHello of our own (Ssl3Probe). ok? means the
      # server accepted SSL 3.0; otherwise `error` says how it refused, or why
      # no TCP connection could be opened (error_kind of the connect failure).
      def ssl3_hello(url)
        uri = URI.parse(url)
        tcp = connect(uri.hostname, uri.port)
        return Handshake.new(error: tcp.error, error_kind: tcp.error_kind) if tcp.is_a?(Response)

        begin
          result = Ssl3Probe.run(tcp, IoDeadline.deadline(@config.connect_timeout))
          return Handshake.new(version: "ssl3") if result.accepted?

          Handshake.new(error: result.text, error_kind: :tls)
        ensure
          tcp.close unless tcp.closed?
        end
      end

      # Response failure if no TCP connection can be opened, otherwise nil.
      def reachable(url)
        uri = URI.parse(url)
        tcp = connect(uri.hostname, uri.port)
        return tcp if tcp.is_a?(Response)

        tcp.close
        nil
      end

      private

      def merge_headers(headers)
        merged = DEFAULT_HEADERS.dup
        headers.each do |name, value|
          merged.delete_if { |k, _| k.casecmp?(name) }
          merged[name] = value
        end
        merged
      end

      def authority(uri)
        host = uri.host
        uri.port == uri.default_port ? host : "#{host}:#{uri.port}"
      end

      def plain(uri, method, headers, body, deadline)
        tcp = connect(uri.hostname, uri.port)
        return tcp if tcp.is_a?(Response)

        begin
          send_request(tcp, "1.1", authority(uri), method, uri.request_uri, headers, body, deadline)
        ensure
          tcp.close unless tcp.closed?
        end
      end

      def send_request(io, speak, authority, method, target, headers, body, deadline)
        if speak == "2"
          Http2.request(io, authority: authority, method: method, target: target, headers: headers, body: body, deadline: deadline)
        else
          Http1.request(io, authority: authority, method: method, target: target, headers: headers, body: body,
                            version: speak, deadline: deadline)
        end
      rescue Timeout
        Response.failure(:timeout, "timed out sending the request")
      rescue Errno::ECONNRESET, Errno::EPIPE, IOError, OpenSSL::SSL::SSLError => e
        Response.failure(:closed, "connection closed while sending the request: #{e.message}")
      end

      def connect(host, port)
        Socket.tcp(host, port, connect_timeout: @config.connect_timeout)
      rescue SocketError => e
        Response.failure(:dns, "#{host} cannot be resolved (#{e.message})")
      rescue *CONNECT_TIMEOUTS => e
        Response.failure(:connect_timeout, "no TCP connection to #{host}:#{port} within #{@config.connect_timeout} s (#{e.message})")
      rescue SystemCallError => e
        Response.failure(:connect, "no TCP connection to #{host}:#{port} (#{e.message})")
      end

      def handshake(tcp, host, alpn:, tls_version:, verify:, lenient: false)
        ctx = OpenSSL::SSL::SSLContext.new
        if verify
          ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
          ctx.cert_store = @config.cert_store
          ctx.verify_hostname = true
        else
          ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end
        ctx.alpn_protocols = alpn if alpn
        if tls_version
          TlsVersions.force(ctx, tls_version)
        elsif lenient
          ctx.security_level = 0
          ctx.ciphers = "DEFAULT:@SECLEVEL=0"
          ctx.min_version = nil
        end
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
        ssl.hostname = host unless ip_address?(host)
        ssl.sync_close = true
        deadline = IoDeadline.deadline(@config.connect_timeout)
        loop do
          result = ssl.connect_nonblock(exception: false)
          case result
          when :wait_readable then IoDeadline.wait(ssl, :read, deadline)
          when :wait_writable then IoDeadline.wait(ssl, :write, deadline)
          else break
          end
        end
        ssl
      rescue Timeout
        Response.failure(:tls, "TLS handshake timed out")
      rescue OpenSSL::SSL::SSLError => e
        classify_tls_error(e)
      rescue Errno::ECONNRESET, Errno::EPIPE, EOFError, IOError => e
        Response.failure(:tls, "connection closed during the TLS handshake (#{e.class.name.split('::').last})")
      end

      def classify_tls_error(error)
        text = error.message
        if text.match?(/alert number 120|no application protocol/i)
          Response.failure(:alpn, "TLS handshake aborted with alert no_application_protocol (ALPN)")
        elsif text.include?("certificate verify failed") || text.include?("hostname")
          Response.failure(:certificate, "certificate not valid: #{text[/certificate verify failed.*|hostname.*/] || text}")
        else
          Response.failure(:tls, "TLS handshake failed: #{text.sub(/\ASSL_connect returned=\d+ errno=\d+ /, '').sub(/peeraddr=\S+ /, '')}")
        end
      end

      def ip_address?(host) = host.match?(/\A[\d.]+\z/) || host.include?(":")
    end
  end
end
