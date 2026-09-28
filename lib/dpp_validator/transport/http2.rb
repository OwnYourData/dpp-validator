require "http/2"

module DppValidator
  module Transport
    # One HTTP/2 request on a TLS connection whose ALPN selected h2, framed
    # with the http-2 gem.
    module Http2
      CONNECTION_FIELDS = %w[host connection keep-alive proxy-connection transfer-encoding upgrade].freeze

      module_function

      def request(io, authority:, method:, target:, headers:, body:, deadline:)
        conn = HTTP2::Client.new
        conn.on(:frame) { |bytes| IoDeadline.write(io, bytes, deadline) }
        status = nil
        fields = {}
        data = +"".b
        closed = false
        reset = nil
        stream = conn.new_stream
        stream.on(:headers) do |pairs|
          code = pairs.find { |k, _| k == ":status" }&.last
          if code && code.to_i >= 200 && status.nil?
            status = code.to_i
            pairs.each { |k, v| (fields[k] ||= []) << v unless k.start_with?(":") }
          end
        end
        stream.on(:data) { |chunk| data << chunk }
        stream.on(:close) { |error| closed = true; reset = error if error && error != :no_error }
        stream.headers(request_headers(authority, method, target, headers, body), end_stream: body.nil?)
        stream.data(body.dup, end_stream: true) if body

        until closed
          chunk = IoDeadline.read(io, deadline)
          break if chunk.nil?

          conn << chunk
        end
        finish(status, fields, data, closed, reset)
      rescue Timeout
        partial(status, fields, data, :timeout, status ? "timed out in the response body" : "timed out: no response")
      rescue HTTP2::Error::Error => e
        partial(status, fields, data, :protocol, "HTTP/2 error: #{e.class.name.split('::').last} #{e.message}".strip)
      rescue Errno::ECONNRESET, Errno::EPIPE, IOError, OpenSSL::SSL::SSLError => e
        partial(status, fields, data, :closed, "connection closed: #{e.message}")
      end

      def request_headers(authority, method, target, headers, body)
        list = [[":method", method], [":scheme", "https"], [":authority", authority], [":path", target]]
        headers.each do |name, value|
          lower = name.downcase
          list << [lower, value.to_s] unless CONNECTION_FIELDS.include?(lower)
        end
        list << ["content-length", body.bytesize.to_s] if body && list.none? { |n, _| n == "content-length" }
        list
      end

      def finish(status, fields, data, closed, reset)
        return partial(status, fields, data, :closed, "connection closed without a response") unless closed
        return partial(status, fields, data, :closed, "stream reset (#{reset})") if reset
        return Response.failure(:protocol, "HTTP/2 stream closed without a status", protocol: "HTTP/2") unless status

        Response.new(status: status, headers: fields, body: data.force_encoding(Encoding::UTF_8), protocol: "HTTP/2")
      end

      def partial(status, fields, data, kind, message)
        return Response.failure(kind, message, protocol: "HTTP/2") unless status

        Response.new(status: status, headers: fields, body: data.force_encoding(Encoding::UTF_8), protocol: "HTTP/2",
                     error: message, error_kind: kind)
      end
    end
  end
end
