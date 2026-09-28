require "http/2"

# A local HTTPS server for the tests, with HTTP/2 and HTTP/1.x and control
# over the parts the checks look at:
#
# protocols:  ALPN protocols the server selects from, in order of preference
# alpn:       :strict (no overlap -> handshake aborted with alert
#             no_application_protocol), :off (ALPN ignored, HTTP/1.x spoken)
# gate:       :h2_only closes the TCP connection before the TLS handshake if
#             the ClientHello does not offer h2 (a TLS abort without alert)
# tls:        [min, max] TLS versions as in the tls check ("1.0", "1.2", ...)
# cert:       :trusted, :self_signed, :other_host (see TestCerts)
#
# The block gets a TestServer::Request and returns [status, headers, body],
# :hang (never answer) or :close (close without an answer). Header values
# may be arrays to send several fields with the same name.
class TestServer
  Request = Struct.new(:protocol, :method, :path, :headers, :body, keyword_init: true)

  attr_reader :port, :requests

  def initialize(protocols: %w[h2 http/1.1], alpn: :strict, gate: nil, tls: nil, cert: :trusted, &handler)
    @protocols = protocols
    @gate = gate
    @handler = handler || ->(_req) { [200, { "Content-Type" => "application/json" }, "{}"] }
    @requests = Queue.new
    @ctx = context(alpn, tls, cert)
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.addr[1]
    @threads = []
    @acceptor = Thread.new { accept_loop }
  end

  def url(path = "") = "https://localhost:#{@port}#{path}"

  def received
    list = []
    list << @requests.pop until @requests.empty?
    list
  end

  def stop
    @tcp.close unless @tcp.closed?
    @acceptor.kill
    @threads.each(&:kill)
  end

  private

  def context(alpn, tls, cert)
    pair = TestCerts.pair(cert)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.key = pair[:key]
    ctx.cert = pair[:cert]
    if tls
      min, max = tls
      ctx.security_level = 0
      ctx.ciphers = "DEFAULT:@SECLEVEL=0"
      ctx.min_version = DppValidator::Transport::TlsVersions::VERSIONS.fetch(min)
      ctx.max_version = DppValidator::Transport::TlsVersions::VERSIONS.fetch(max)
    end
    if alpn == :strict
      protocols = @protocols
      ctx.alpn_select_cb = lambda do |offered|
        protocols.find { |p| offered.include?(p) } or raise "no common ALPN protocol"
      end
    end
    ctx
  end

  def accept_loop
    loop do
      sock = @tcp.accept
      @threads << Thread.new { serve(sock) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def serve(sock)
    return sock.close if @gate == :h2_only && !offers_h2?(sock)

    ssl = OpenSSL::SSL::SSLSocket.new(sock, @ctx)
    ssl.sync_close = true
    ssl.accept
    ssl.alpn_protocol == "h2" ? serve_h2(ssl) : serve_h1(ssl)
  rescue StandardError
    nil
  ensure
    sock.close unless sock.closed?
  end

  def offers_h2?(sock)
    return false unless IO.select([sock], nil, nil, 2)

    sock.recv(16_384, Socket::MSG_PEEK).b.include?("\x02h2".b)
  end

  def respond(request)
    @requests << request
    @handler.call(request)
  end

  def serve_h1(io)
    head = +"".b
    head << io.readpartial(16_384) until head.include?("\r\n\r\n")
    header_part, rest = head.split("\r\n\r\n", 2)
    lines = header_part.split("\r\n")
    method, path, version = lines.shift.split(" ", 3)
    headers = Hash.new { |h, k| h[k] = [] }
    lines.each { |l| name, value = l.split(":", 2); headers[name.strip.downcase] << value.to_s.strip }
    body = rest.to_s
    length = headers["content-length"].first.to_i
    body << io.readpartial(16_384) while body.bytesize < length
    result = respond(Request.new(protocol: version, method: method, path: path, headers: headers.to_h, body: body))
    return sleep(30) if result == :hang
    return if result == :close

    status, fields, text = result
    out = +"#{version == 'HTTP/1.0' ? 'HTTP/1.0' : 'HTTP/1.1'} #{status} Test\r\n"
    fields.each { |name, value| Array(value).each { |v| out << "#{name}: #{v}\r\n" } }
    out << "Content-Length: #{text.to_s.bytesize}\r\nConnection: close\r\n\r\n#{text}"
    io.write(out)
  end

  def serve_h2(io)
    conn = HTTP2::Server.new
    conn.on(:frame) { |bytes| io.write(bytes) }
    conn.on(:stream) do |stream|
      headers = {}
      body = +""
      stream.on(:headers) { |pairs| pairs.each { |k, v| headers[k] = v } }
      stream.on(:data) { |d| body << d }
      stream.on(:half_close) do
        request = Request.new(protocol: "HTTP/2", method: headers[":method"], path: headers[":path"],
                              headers: headers.reject { |k, _| k.start_with?(":") }, body: body)
        result = respond(request)
        if result == :close
          io.close
        elsif result != :hang
          status, fields, text = result
          pairs = [[":status", status.to_s]]
          fields.each { |name, value| Array(value).each { |v| pairs << [name.downcase, v] } }
          stream.headers(pairs, end_stream: text.to_s.empty?)
          stream.data(text.to_s.dup) unless text.to_s.empty?
        end
      end
    end
    loop { conn << io.readpartial(16_384) }
  end
end

# Plain HTTP/1.1 server (for https_redirect).
class PlainTestServer
  attr_reader :port

  def initialize(&handler)
    @handler = handler
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.addr[1]
    @acceptor = Thread.new do
      loop do
        sock = @tcp.accept
        Thread.new do
          head = +""
          head << sock.readpartial(4096) until head.include?("\r\n\r\n")
          status, fields, text = @handler.call(head.lines.first)
          out = +"HTTP/1.1 #{status} Test\r\n"
          fields.each { |n, v| out << "#{n}: #{v}\r\n" }
          out << "Content-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}"
          sock.write(out)
        rescue StandardError
          nil
        ensure
          sock.close
        end
      end
    rescue IOError, Errno::EBADF
      nil
    end
  end

  def stop
    @tcp.close unless @tcp.closed?
    @acceptor.kill
  end
end
