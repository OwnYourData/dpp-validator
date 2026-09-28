module DppValidator
  module Transport
    # TLS versions as named in the tls check type, and whether this runner's
    # OpenSSL can offer them at all.
    #
    # OpenSSL 3 refuses TLS 1.0 and 1.1 at the default security level and is
    # often built without SSL 3.0. A forced handshake that fails for that
    # reason on the client side would look like a server that rejects the
    # version. Before a version is tested against a service, `offerable?`
    # therefore runs a handshake at exactly that version against a loopback
    # server in this process, with security level 0; only if that succeeds is
    # the version tested (otherwise the criterion is skipped with the reason).
    module TlsVersions
      VERSIONS = {
        "ssl3" => OpenSSL::SSL::SSL3_VERSION,
        "1.0" => OpenSSL::SSL::TLS1_VERSION,
        "1.1" => OpenSSL::SSL::TLS1_1_VERSION,
        "1.2" => OpenSSL::SSL::TLS1_2_VERSION,
        "1.3" => OpenSSL::SSL::TLS1_3_VERSION
      }.freeze
      NAMES = { "ssl3" => "SSL 3.0", "1.0" => "TLS 1.0", "1.1" => "TLS 1.1", "1.2" => "TLS 1.2", "1.3" => "TLS 1.3" }.freeze
      # OpenSSL's names of negotiated versions (SSLSocket#ssl_version)
      NEGOTIATED = { "SSLv3" => "ssl3", "TLSv1" => "1.0", "TLSv1.1" => "1.1", "TLSv1.2" => "1.2", "TLSv1.3" => "1.3" }.freeze
      LEGACY = %w[ssl3 1.0 1.1].freeze

      @offerable = {}
      @lock = Mutex.new

      module_function

      def name(version) = NAMES.fetch(version, version.to_s)
      def rank(version) = VERSIONS.keys.index(version) || -1
      def from_negotiated(text) = NEGOTIATED[text]

      # Applies a forced version to a client or server context.
      def force(ctx, version)
        code = VERSIONS.fetch(version)
        if LEGACY.include?(version)
          ctx.security_level = 0
          ctx.ciphers = "DEFAULT:@SECLEVEL=0"
        end
        ctx.min_version = code
        ctx.max_version = code
      end

      # nil if this runner can offer the version, otherwise the reason.
      def offer_problem(version)
        @lock.synchronize do
          @offerable[version] = probe(version) unless @offerable.key?(version)
          @offerable[version]
        end
      end

      def offerable?(version) = offer_problem(version).nil?

      def probe(version)
        key = OpenSSL::PKey::RSA.new(2048)
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = 1
        cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
        cert.public_key = key
        cert.not_before = Time.now - 60
        cert.not_after = Time.now + 600
        cert.sign(key, "SHA256")

        server_ctx = OpenSSL::SSL::SSLContext.new
        server_ctx.key = key
        server_ctx.cert = cert
        force(server_ctx, version)
        client_ctx = OpenSSL::SSL::SSLContext.new
        client_ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
        force(client_ctx, version)

        tcp = TCPServer.new("127.0.0.1", 0)
        server = Thread.new do
          sock = tcp.accept
          ssl = OpenSSL::SSL::SSLSocket.new(sock, server_ctx)
          begin
            ssl.accept
          rescue StandardError
            nil
          ensure
            sock.close
          end
        end
        sock = TCPSocket.new("127.0.0.1", tcp.addr[1])
        ssl = OpenSSL::SSL::SSLSocket.new(sock, client_ctx)
        begin
          ssl.connect
          got = from_negotiated(ssl.ssl_version)
          got == version ? nil : "the local OpenSSL negotiated #{name(got)} instead of #{name(version)}"
        ensure
          sock.close
          server.join(5)
          tcp.close
        end
      rescue StandardError => e
        detail = e.message.sub(/\A.*state=error: /, "")
        "the OpenSSL of this runner (#{OpenSSL::OPENSSL_LIBRARY_VERSION}) cannot offer #{name(version)} (#{detail})"
      end
    end
  end
end
