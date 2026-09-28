module DppValidator
  module Transport
    # One HTTP/1.0 or HTTP/1.1 request on an open connection (plain or TLS),
    # with "Connection: close". The response ends with Content-Length, the
    # last chunk of a chunked body, or the end of the connection.
    module Http1
      STATUS_LINE = %r{\AHTTP/(\d)\.(\d) (\d{3})(?: [^\r\n]*)?\z}

      module_function

      def request(io, authority:, method:, target:, headers:, body:, version:, deadline:)
        IoDeadline.write(io, serialize(authority, method, target, headers, body, version), deadline)
        read_response(io, head: method == "HEAD", deadline: deadline)
      end

      def serialize(authority, method, target, headers, body, version)
        lines = ["#{method} #{target} HTTP/#{version}", "Host: #{authority}"]
        headers.each { |name, value| lines << "#{name}: #{value}" unless name.casecmp?("host") }
        lines << "Content-Length: #{body.bytesize}" if body && headers.keys.none? { |n| n.casecmp?("content-length") }
        lines << "Connection: close"
        "#{lines.join("\r\n")}\r\n\r\n#{body}"
      end

      def read_response(io, head:, deadline:)
        buffer = +"".b
        protocol = nil
        status = nil
        fields = {}
        loop do
          until (split = buffer.index("\r\n\r\n"))
            chunk = read_or_timeout(io, deadline, buffer.empty? ? "no response" : "incomplete response header")
            return chunk if chunk.is_a?(Response)
            return Response.failure(:closed, buffer.empty? ? "connection closed without a response" : "connection closed in the response header") if chunk.nil?

            buffer << chunk
          end
          head_lines = buffer.byteslice(0, split).force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8).split("\r\n")
          buffer = buffer.byteslice(split + 4..)
          m = STATUS_LINE.match(head_lines.shift.to_s)
          return Response.failure(:protocol, "not an HTTP/1.x status line") unless m

          protocol = "HTTP/#{m[1]}.#{m[2]}"
          status = m[3].to_i
          fields = parse_fields(head_lines)
          break unless status < 200 && status != 101
        end
        body_complete, body, error = read_body(io, buffer, fields, status, head, deadline)
        res = Response.new(status: status, headers: fields, body: body.force_encoding(Encoding::UTF_8), protocol: protocol)
        unless body_complete
          res.error = error
          res.error_kind = error.start_with?("timed out") ? :timeout : :closed
        end
        res
      end

      def read_or_timeout(io, deadline, what)
        IoDeadline.read(io, deadline)
      rescue Timeout
        Response.failure(:timeout, "timed out: #{what}")
      rescue Errno::ECONNRESET, Errno::EPIPE, IOError, OpenSSL::SSL::SSLError => e
        Response.failure(:closed, "connection closed: #{e.message}")
      end

      def parse_fields(lines)
        fields = {}
        lines.each do |line|
          name, value = line.split(":", 2)
          next if value.nil?

          (fields[name.strip.downcase] ||= []) << value.strip
        end
        fields
      end

      # [complete, body, error]
      def read_body(io, buffer, fields, status, head, deadline)
        return [true, +"".b, nil] if head || status == 204 || status == 304

        chunked = fields.fetch("transfer-encoding", []).join(",").downcase.include?("chunked")
        length = fields["content-length"]&.first&.to_i
        loop do
          if chunked
            decoded = decode_chunked(buffer)
            return [true, decoded, nil] if decoded
          elsif length && buffer.bytesize >= length
            return [true, buffer.byteslice(0, length), nil]
          end
          chunk = IoDeadline.read(io, deadline)
          if chunk.nil?
            return [true, buffer, nil] unless chunked || length

            return [false, buffer, "connection closed in the response body"]
          end
          buffer << chunk
        end
      rescue Timeout
        [false, buffer, "timed out in the response body"]
      rescue Errno::ECONNRESET, Errno::EPIPE, IOError, OpenSSL::SSL::SSLError => e
        [false, buffer, "connection closed in the response body: #{e.message}"]
      end

      # The decoded body, or nil while the chunked body is incomplete.
      def decode_chunked(buffer)
        out = +"".b
        pos = 0
        loop do
          eol = buffer.index("\r\n", pos)
          return nil unless eol

          size = buffer.byteslice(pos, eol - pos).split(";").first.to_s.strip.to_i(16)
          pos = eol + 2
          if size.zero?
            return buffer.index("\r\n\r\n", pos - 2) ? out : nil
          end
          return nil if buffer.bytesize < pos + size + 2

          out << buffer.byteslice(pos, size)
          pos += size + 2
        end
      end
    end
  end
end
