require_relative "test_helper"

class TransportTest < ValidatorTestCase
  def client(**overrides) = DppValidator::Transport::Client.new(config(**overrides))

  test "default negotiation speaks HTTP/2 if the server selects h2, HTTP/1.1 otherwise" do
    h2 = server { |r| [200, { "Content-Type" => "text/plain" }, r.protocol] }
    res = client.request(h2.url("/a"))
    assert_equal ["HTTP/2", "h2", "HTTP/2"], [res.protocol, res.alpn, res.body]
    h1 = server(protocols: %w[http/1.1]) { |r| [200, {}, r.protocol] }
    res = client.request(h1.url("/a"))
    assert_equal ["HTTP/1.1", "http/1.1", "HTTP/1.1"], [res.protocol, res.alpn, res.body]
  end

  test "forced versions offer only that protocol in ALPN" do
    s = server(alpn: :off) { |r| [200, {}, r.protocol] }
    assert_equal "HTTP/1.0", client.request(s.url("/"), http_version: "1.0").body
    assert_equal "HTTP/1.1", client.request(s.url("/"), http_version: "1.1").body
    res = client.request(s.url("/"), http_version: "2")
    assert_equal :alpn_not_selected, res.error_kind
  end

  test "ALPN no_application_protocol is recognised" do
    s = server(protocols: %w[h2])
    res = client.request(s.url("/"), http_version: "1.1")
    assert_equal :alpn, res.error_kind
    assert_match(/no_application_protocol/, res.error)
  end

  test "header fields keep every line, names in lower case, for HTTP/1.1 and HTTP/2" do
    [%w[h2 http/1.1], %w[http/1.1]].each do |protocols|
      s = server(protocols: protocols) { [200, { "Vary" => %w[Origin Accept], "X-Test" => "a" }, "x"] }
      res = client.request(s.url("/"))
      assert_equal %w[Origin Accept], res.headers["vary"], protocols.inspect
      assert_equal "Origin, Accept", res.header("VARY")
    end
  end

  test "request method, headers and body arrive at the server" do
    s = server(protocols: %w[http/1.1]) { [201, {}, ""] }
    res = client.request(s.url("/dpp/v1/dpps?x=1"), method: "POST", headers: { "Content-Type" => "application/json" }, body: "{}")
    assert_equal 201, res.status
    req = s.received.first
    assert_equal ["POST", "/dpp/v1/dpps?x=1", "{}"], [req.method, req.path, req.body]
    assert_equal ["application/json"], req.headers["content-type"]
    assert_equal [DppValidator::USER_AGENT], req.headers["user-agent"]
  end

  test "timeout without a response and connection closed without a response" do
    hang = server { :hang }
    res = client(read_timeout: 0.5).request(hang.url("/"))
    assert_equal :timeout, res.error_kind
    refute res.status?
    close = server(protocols: %w[http/1.1]) { :close }
    res = client.request(close.url("/"))
    assert_equal :closed, res.error_kind
  end

  test "no TCP connection counts as not reachable" do
    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.addr[1]
    tcp.close
    res = client.request("https://127.0.0.1:#{port}/")
    assert res.unreachable?, res.error
  end

  test "certificate verification: trusted CA passes, self-signed and wrong host fail" do
    assert client.request(server.url("/")).status?
    res = client.request(server(cert: :self_signed).url("/"))
    assert_equal :certificate, res.error_kind
    res = client.request(server(cert: :other_host).url("/"))
    assert_equal :certificate, res.error_kind
    assert client.request(server(cert: :self_signed).url("/"), verify: false).status?
  end

  test "TLS versions this runner can offer are checked against a loopback server" do
    assert DppValidator::Transport::TlsVersions.offerable?("1.2")
    assert DppValidator::Transport::TlsVersions.offerable?("1.3")
    problem = DppValidator::Transport::TlsVersions.offer_problem("ssl3")
    assert_match(/cannot offer SSL 3\.0/, problem) if problem
  end
end
