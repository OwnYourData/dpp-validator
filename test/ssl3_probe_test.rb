require_relative "test_helper"

# The SSL 3.0 test with a ClientHello of our own, against raw TCP servers that
# answer with prepared bytes, and against a real OpenSSL 3 server.
class Ssl3ProbeTest < ValidatorTestCase
  PROBE = DppValidator::Transport::Ssl3Probe

  # A TCP server that reads one TLS record, keeps it in @hello and then
  # answers with `answer` (bytes), closes (:close) or stays silent (:hang).
  def raw_server(answer)
    tcp = TCPServer.new("127.0.0.1", 0)
    @hello = nil
    thread = Thread.new do
      sock = tcp.accept
      begin
        header = sock.read(5)
        @hello = header + sock.read(header.unpack("Cnn")[2])
        case answer
        when :close then nil
        when :hang then sleep 3
        else sock.write(answer)
        end
      rescue StandardError
        nil
      ensure
        sock.close
      end
    end
    @raw = [tcp, thread]
    "https://127.0.0.1:#{tcp.addr[1]}"
  end

  def teardown
    super
    return unless @raw

    @raw[1].join(5)
    @raw[0].close
  end

  def client = DppValidator::Transport::Client.new(config(connect_timeout: 1))

  def record(type, payload) = [type, 0x0300, payload.bytesize].pack("Cnn") + payload

  def server_hello(version)
    body = [version].pack("n") + ("\x00" * 32) + [0].pack("C") + [0x002F].pack("n") + [0].pack("C")
    record(0x16, [2].pack("C") + [body.bytesize].pack("N").byteslice(1, 3) + body)
  end

  test "the ClientHello is an SSL 3.0 hello without extensions and without TLS_FALLBACK_SCSV" do
    hello = PROBE.client_hello
    type, record_version, length = hello.unpack("Cnn")
    assert_equal [0x16, 0x0300, hello.bytesize - 5], [type, record_version, length]
    assert_equal 1, hello.getbyte(5)
    assert_equal 0x0300, hello.byteslice(9, 2).unpack1("n")
    suites_length = hello.byteslice(44, 2).unpack1("n")
    suites = hello.byteslice(46, suites_length).unpack("n*")
    refute_includes suites, PROBE::FALLBACK_SCSV
    assert_equal [1, 0], hello.byteslice(46 + suites_length, 2).unpack("CC")
    assert_equal hello.bytesize, 46 + suites_length + 2, "no extensions after the compression methods"
  end

  test "an SSL 3.0 ServerHello means accepted" do
    hs = client.ssl3_hello(raw_server(server_hello(0x0300)))
    assert hs.ok?
    assert_equal "ssl3", hs.version
    assert_equal 0x0300, @hello.unpack("Cnn")[1]
  end

  test "an alert, a ServerHello for another version, data that is not TLS, a close or no answer mean refused" do
    {
      record(0x15, [2, 70].pack("CC")) => /TLS alert protocol_version/,
      record(0x15, [2, 40].pack("CC")) => /TLS alert handshake_failure/,
      server_hello(0x0303) => /ServerHello for TLS 1\.2/,
      "HTTP/1.1 400 Bad Request\r\n\r\n" => /not a TLS record \(first byte 0x48\)/,
      :close => /connection closed without an answer/,
      :hang => /no answer .* in time/
    }.each do |answer, text|
      hs = client.ssl3_hello(raw_server(answer))
      refute hs.ok?, text.source
      assert_equal :tls, hs.error_kind
      assert_match text, hs.error
      teardown
      @raw = nil
    end
  end

  test "a real OpenSSL 3 server refuses SSL 3.0" do
    hs = client.ssl3_hello(server(tls: %w[1.2 1.3]).url("/"))
    refute hs.ok?
    assert_match(/TLS alert|connection closed/, hs.error)
  end

  test "no TCP connection is reported with the kind of the connect failure" do
    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.addr[1]
    tcp.close
    hs = client.ssl3_hello("https://127.0.0.1:#{port}")
    refute hs.ok?
    assert_includes DppValidator::Transport::UNREACHABLE, hs.error_kind
  end
end
