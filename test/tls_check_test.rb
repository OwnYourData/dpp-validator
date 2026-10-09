require_relative "test_helper"

class TlsCheckTest < ValidatorTestCase
  REJECT_OLD_HTTP = { "type" => "tls", "http_versions" => { "reject" => %w[1.0 1.1] } }.freeze
  VERSIONS = DppValidator::Transport::TlsVersions

  def base(s) = s.url("/dpp/v1")

  # HTTP/2 answers 200; HTTP/1.x gets the given answer.
  def old_http(answer, **options)
    server(protocols: %w[h2 http/1.1 http/1.0], **options) { |r| r.protocol == "HTTP/2" ? json(200, {}) : answer }
  end

  # --- http_versions.reject ------------------------------------------------

  test "reject: TLS handshake aborted when ALPN does not offer h2 -> rejected" do
    s = server(protocols: %w[h2], alpn: :off, gate: :h2_only) { json(200, {}) }
    outcome = run_check(REJECT_OLD_HTTP, base(s))
    assert_result "passed", outcome
    assert_match(/HTTP\/1\.1 rejected \(connection closed during the TLS handshake/, outcome.details.join("\n"))
  end

  test "reject: ALPN alert no_application_protocol -> rejected" do
    outcome = run_check(REJECT_OLD_HTTP, base(server(protocols: %w[h2]) { json(200, {}) }))
    assert_result "passed", outcome
    assert_match(/HTTP\/1\.0 rejected \(TLS handshake aborted with alert no_application_protocol/, outcome.details.join("\n"))
  end

  test "reject: timeout without a response -> rejected" do
    outcome = run_check(REJECT_OLD_HTTP, base(old_http(:hang)))
    assert_result "passed", outcome
    assert_match(/HTTP\/1\.1 rejected \(timed out: no response\)/, outcome.details.join("\n"))
  end

  test "reject: connection closed without a response -> rejected" do
    assert_result "passed", run_check(REJECT_OLD_HTTP, base(old_http(:close)))
  end

  test "reject: status 400 and 505 -> rejected" do
    [400, 505].each do |status|
      outcome = run_check(REJECT_OLD_HTTP, base(old_http([status, {}, ""])))
      assert_result "passed", outcome
      assert_match(/HTTP\/1\.1 rejected \(status #{status}\)/, outcome.details.join("\n"))
    end
  end

  test "reject: 200 and 301 -> not rejected, failed" do
    [[200, {}, "{}"], [301, { "Location" => "https://elsewhere.example/" }, ""]].each do |answer|
      outcome = run_check(REJECT_OLD_HTTP, base(old_http(answer)))
      assert_result "failed", outcome
      assert_equal ["error: HTTP/1.0 not rejected: answered #{answer[0]} (ALPN offered only http/1.0)",
                    "error: HTTP/1.1 not rejected: answered #{answer[0]} (ALPN offered only http/1.1)"], messages_text(outcome)
    end
  end

  test "reject: one version accepted is enough to fail" do
    s = server(protocols: %w[h2 http/1.1 http/1.0]) { |r| r.protocol == "HTTP/1.1" ? json(200, {}) : json(r.protocol == "HTTP/2" ? 200 : 505, {}) }
    outcome = run_check(REJECT_OLD_HTTP, base(s))
    assert_result "failed", outcome
    assert_equal ["error: HTTP/1.1 not rejected: answered 200 (ALPN offered only http/1.1)"], messages_text(outcome)
  end

  test "reject: HTTP/1.1 served on the default negotiation (no h2) fails" do
    outcome = run_check(REJECT_OLD_HTTP, base(server(protocols: %w[http/1.1 http/1.0]) { json(200, {}) }))
    assert_result "failed", outcome
  end

  test "reject: reference request without 2xx/3xx -> skipped, 4xx at the forced version says nothing" do
    s = server(protocols: %w[h2 http/1.1 http/1.0]) { json(404, {}) }
    outcome = run_check(REJECT_OLD_HTTP, base(s))
    assert_result "skipped", outcome
    assert_match(/reference request .* gave HTTP 404 over HTTP\/2, not 2xx or 3xx/, outcome.reason)
    assert_equal "not_evaluated", outcome.reason_code
    s = server(protocols: %w[h2 http/1.1]) { :hang }
    assert_result "skipped", run_check(REJECT_OLD_HTTP, base(s))
  end

  test "reject: the forced requests go to GET {base}/dpps/{dppId} with the requested version" do
    s = old_http([505, {}, ""])
    run_check(REJECT_OLD_HTTP, base(s))
    seen = s.received.map { |r| [r.protocol, r.method, r.path] }
    assert_equal [["HTTP/2", "GET", "/dpp/v1/dpps/did%3Aoyd%3AzQmTest1"], ["HTTP/1.0", "GET", "/dpp/v1/dpps/did%3Aoyd%3AzQmTest1"],
                  ["HTTP/1.1", "GET", "/dpp/v1/dpps/did%3Aoyd%3AzQmTest1"]], seen
  end

  # --- http_versions.require -----------------------------------------------

  test "require HTTP/2: selected in ALPN and answered -> passed; not offered -> failed; HTTP/3 not tested" do
    check = { "type" => "tls", "http_versions" => { "require" => ["2"] } }
    assert_result "passed", run_check(check, base(server { json(200, {}) }))
    outcome = run_check(check, base(server(protocols: %w[http/1.1]) { json(200, {}) }))
    assert_result "failed", outcome
    assert_match(/HTTP\/2 not supported: no response \(TLS handshake aborted with alert no_application_protocol/, messages_text(outcome).first)
    outcome = run_check({ "type" => "tls", "http_versions" => { "require" => ["3"] } }, base(server { json(200, {}) }))
    assert_result "skipped", outcome
    assert_match(/does not speak QUIC/, outcome.reason)
  end

  # --- TLS versions ----------------------------------------------------------

  test "reject_versions: TLS 1.0 and 1.1 refused by a TLS 1.2+ server -> passed" do
    skip "this OpenSSL cannot offer TLS 1.0/1.1" unless VERSIONS.offerable?("1.0") && VERSIONS.offerable?("1.1")
    outcome = run_check({ "type" => "tls", "reject_versions" => %w[1.0 1.1] }, base(server(tls: %w[1.2 1.3])))
    assert_result "passed", outcome
    assert_match(/TLS 1\.0 refused/, outcome.details.join("\n"))
  end

  test "reject_versions: TLS 1.0 accepted -> failed" do
    skip "this OpenSSL cannot offer TLS 1.0" unless VERSIONS.offerable?("1.0")
    outcome = run_check({ "type" => "tls", "reject_versions" => %w[1.0 1.1] }, base(server(tls: %w[1.0 1.3])))
    assert_result "failed", outcome
    assert_equal ["error: TLS 1.0 accepted", "error: TLS 1.1 accepted"], messages_text(outcome)
  end

  test "reject_versions: SSL 3.0 is tested with a ClientHello of our own and refused by OpenSSL 3" do
    outcome = run_check({ "type" => "tls", "reject_versions" => %w[ssl3] }, base(server(tls: %w[1.2 1.3])))
    assert_result "passed", outcome
    assert_match(/SSL 3\.0 refused \(/, outcome.details.join("\n"))
  end

  test "a failed part beats a part that could not be tested" do
    skip "this OpenSSL cannot offer TLS 1.0" unless VERSIONS.offerable?("1.0")
    check = { "type" => "tls", "reject_versions" => %w[1.0], "http_versions" => { "require" => ["3"] } }
    outcome = run_check(check, base(server(tls: %w[1.0 1.3]) { json(200, {}) }))
    assert_result "failed", outcome
  end

  test "recommend_versions: TLS 1.3 missing -> warning" do
    assert_result "passed", run_check({ "type" => "tls", "recommend_versions" => ["1.3"] }, base(server))
    outcome = run_check({ "type" => "tls", "recommend_versions" => ["1.3"] }, base(server(tls: %w[1.2 1.2])))
    assert_result "warning", outcome
    assert_match(/TLS 1\.3 not supported/, messages_text(outcome).first)
  end

  test "min_version: negotiated version below the minimum -> failed" do
    assert_result "passed", run_check({ "type" => "tls", "min_version" => "1.2" }, base(server))
    skip "this OpenSSL cannot offer TLS 1.1" unless VERSIONS.offerable?("1.1")
    outcome = run_check({ "type" => "tls", "min_version" => "1.2" }, base(server(tls: %w[1.0 1.1])))
    assert_result "failed", outcome
    assert_equal ["error: negotiated TLS 1.1, expected at least TLS 1.2"], messages_text(outcome)
  end

  # --- certificate and plain HTTP ------------------------------------------

  test "valid_certificate" do
    assert_result "passed", run_check({ "type" => "tls", "valid_certificate" => true }, base(server))
    outcome = run_check({ "type" => "tls", "valid_certificate" => true }, base(server(cert: :self_signed)))
    assert_result "failed", outcome
    assert_match(/certificate not valid/, messages_text(outcome).first)
    assert_result "failed", run_check({ "type" => "tls", "valid_certificate" => true }, base(server(cert: :other_host)))
  end

  test "https_redirect: redirect to https, refusal and error status pass; 200 and redirect to http fail" do
    tls = server
    check = { "type" => "tls", "https_redirect" => true }
    {
      [301, { "Location" => "https://localhost/dpp/v1/dpps/x" }, ""] => "passed",
      [404, {}, "not here"] => "passed",
      [200, { "Content-Type" => "application/json" }, "{}"] => "failed",
      [302, { "Location" => "http://localhost/other" }, ""] => "failed"
    }.each do |answer, expected|
      plain = plain_server { answer }
      assert_result expected, run_check(check, base(tls), config: config(http_port: plain.port))
    end
    tcp = TCPServer.new("127.0.0.1", 0)
    closed_port = tcp.addr[1]
    tcp.close
    outcome = run_check(check, base(tls), config: config(http_port: closed_port))
    assert_result "passed", outcome
    assert_match(/plain HTTP on port #{closed_port} refused/, outcome.details.join)
  end

  test "a host that does not accept TCP connections is skipped" do
    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.addr[1]
    tcp.close
    outcome = run_check(REJECT_OLD_HTTP, "https://127.0.0.1:#{port}/dpp/v1")
    assert_result "skipped", outcome
    assert_match(/service not reachable/, outcome.reason)
    assert_equal "unreachable", outcome.reason_code
  end
end
