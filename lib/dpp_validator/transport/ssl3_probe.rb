module DppValidator
  module Transport
    # SSL 3.0 test with a ClientHello of our own.
    #
    # OpenSSL 3 cannot offer SSL 3.0, so a forced OpenSSL handshake cannot
    # tell whether a server would accept it. CRITERIA-FORMAT.md ("tls") lets
    # a runner send a minimal ClientHello of its own instead. This module
    # sends one SSL 3.0 ClientHello record (record and client version 3.0,
    # no extensions, no TLS_FALLBACK_SCSV) and judges only the server's first
    # record:
    #
    # - a ServerHello with version 3.0: SSL 3.0 accepted;
    # - an alert, a ServerHello with another version, another record, data
    #   that is not TLS, a closed connection or no answer in time: refused.
    #
    # The handshake is never completed; no key exchange takes place.
    module Ssl3Probe
      SSL3 = 0x0300
      # Cipher suites an SSL 3.0 client typically offered, plus the
      # renegotiation SCSV (RFC 5746).
      CIPHER_SUITES = [0x0035, 0x002F, 0x0039, 0x0033, 0x000A, 0x0016, 0x0005, 0x0004, 0x00FF].freeze
      FALLBACK_SCSV = 0x5600
      VERSION_NAMES = { 0x0300 => "SSL 3.0", 0x0301 => "TLS 1.0", 0x0302 => "TLS 1.1", 0x0303 => "TLS 1.2", 0x0304 => "TLS 1.3" }.freeze
      ALERTS = { 0 => "close_notify", 10 => "unexpected_message", 20 => "bad_record_mac", 40 => "handshake_failure",
                 47 => "illegal_parameter", 50 => "decode_error", 70 => "protocol_version", 71 => "insufficient_security",
                 80 => "internal_error", 86 => "inappropriate_fallback", 112 => "unrecognized_name" }.freeze

      Result = Struct.new(:accepted, :text) do
        def accepted? = accepted
      end

      module_function

      def client_hello(random = SecureRandom.random_bytes(32))
        suites = CIPHER_SUITES.pack("n*")
        body = [SSL3].pack("n") + random.b + [0].pack("C") + [suites.bytesize].pack("n") + suites + [1, 0].pack("CC")
        handshake = [1].pack("C") + [body.bytesize].pack("N").byteslice(1, 3) + body
        [0x16, SSL3, handshake.bytesize].pack("Cnn") + handshake
      end

      # io: a connected TCP socket. Returns a Result.
      def run(io, deadline)
        IoDeadline.write(io, client_hello, deadline)
        header = read_exactly(io, 5, deadline)
        return Result.new(false, "connection closed without an answer to the SSL 3.0 ClientHello") if header.nil?

        type, _record_version, length = header.unpack("Cnn")
        case type
        when 0x15 then alert(io, length, deadline)
        when 0x16 then server_hello(io, length, deadline)
        else Result.new(false, format("the answer to the SSL 3.0 ClientHello is not a TLS record (first byte 0x%02X)", type))
        end
      rescue Timeout
        Result.new(false, "no answer to the SSL 3.0 ClientHello in time")
      rescue Errno::ECONNRESET, Errno::EPIPE, EOFError, IOError => e
        Result.new(false, "connection closed after the SSL 3.0 ClientHello (#{e.class.name.split('::').last})")
      end

      def alert(io, length, deadline)
        payload = read_exactly(io, [length, 2].min, deadline)
        description = payload&.getbyte(1)
        name = description && (ALERTS[description] || "number #{description}")
        Result.new(false, name ? "SSL 3.0 ClientHello answered with TLS alert #{name}" : "SSL 3.0 ClientHello answered with a TLS alert")
      end

      def server_hello(io, length, deadline)
        payload = read_exactly(io, [length, 6].min, deadline)
        return Result.new(false, "connection closed during the answer to the SSL 3.0 ClientHello") if payload.nil? || payload.bytesize < 6

        unless payload.getbyte(0) == 2
          return Result.new(false, "SSL 3.0 ClientHello answered with handshake message type #{payload.getbyte(0)}, not a ServerHello")
        end

        version = payload.byteslice(4, 2).unpack1("n")
        return Result.new(true, "SSL 3.0 ClientHello answered with an SSL 3.0 ServerHello") if version == SSL3

        Result.new(false, "SSL 3.0 ClientHello answered with a ServerHello for #{VERSION_NAMES.fetch(version, format('version 0x%04X', version))}")
      end

      # Exactly `count` bytes, or nil if the stream ends before.
      def read_exactly(io, count, deadline)
        data = +"".b
        while data.bytesize < count
          chunk = IoDeadline.read(io, deadline, count - data.bytesize)
          return nil if chunk.nil?

          data << chunk.b
        end
        data
      end
    end
  end
end
