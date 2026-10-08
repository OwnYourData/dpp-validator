require_relative "test_helper"

class HttpCheckTest < ValidatorTestCase
  PASSPORT = { "digitalProductPassportId" => DPP_ID, "uniqueProductIdentifier" => PRODUCT_ID, "dppStatus" => "Active" }.freeze

  def check(*steps, **extra) = { "type" => "http", "steps" => steps }.merge(extra.transform_keys(&:to_s))
  def get(path, expect, **extra) = { "request" => { "method" => "GET", "path" => path, "auth" => "none" }, "expect" => expect }.merge(extra.transform_keys(&:to_s))

  def base(s) = s.url("/dpp/v1")

  test "status and JSON assertion with placeholders pass (DPP-API-013 form)" do
    s = server { |r| r.path == "/dpp/v1/dpps/did%3Aoyd%3AzQmTest1" ? json(200, PASSPORT) : json(404, { "message" => "nope" }) }
    outcome = run_check(check(get("/dpps/{dppId}", { "status" => [200], "content_type" => "application/json",
                                                     "json" => [{ "path" => "$.digitalProductPassportId", "equals" => "{dppId}" }] })), base(s))
    assert_result "passed", outcome
    assert_equal "HTTP/2", s.received.first.protocol
  end

  test "wrong status fails with the step named" do
    s = server { json(500, { "error" => "x" }) }
    outcome = run_check(check(get("/dpps/{randomId}", { "status" => [404] })), base(s))
    assert_result "failed", outcome
    assert_equal ["error: step 1 (GET /dpps/{randomId}): HTTP status is 500, expected 404"], messages_text(outcome)
  end

  test "order: a failed status suppresses content_type-dependent, header and JSON messages" do
    s = server { [500, { "Content-Type" => "text/html" }, "<html>"] }
    outcome = run_check(check(get("/dpps/{dppId}", { "status" => [200], "content_type" => "application/json",
                                                     "headers" => [{ "name" => "Vary", "contains" => "Accept" }],
                                                     "json" => [{ "path" => "$.a", "exists" => true }],
                                                     "body_equals_step" => 1 })), base(s))
    assert_result "failed", outcome
    assert_equal ["error: step 1 (GET /dpps/{dppId}): HTTP status is 500, expected 200",
                  "error: step 1 (GET /dpps/{dppId}): Content-Type is text/html, expected application/json"], messages_text(outcome)
  end

  test "order: a wrong content type suppresses header and JSON messages" do
    s = server { [200, { "Content-Type" => "text/html" }, "<html>"] }
    outcome = run_check(check(get("/x", { "status" => [200], "content_type" => "application/json",
                                          "headers" => [{ "name" => "Vary", "exists" => true }],
                                          "json" => [{ "path" => "$.a", "exists" => true }] })), base(s))
    assert_equal ["error: step 1 (GET /x): Content-Type is text/html, expected application/json"], messages_text(outcome)
  end

  test "order: headers and JSON are evaluated once status and content type hold" do
    s = server { json(200, { "b" => 1 }) }
    outcome = run_check(check(get("/x", { "status" => [200], "content_type" => "application/json",
                                          "headers" => [{ "name" => "Vary", "exists" => true, "severity" => "warning" }],
                                          "json" => [{ "path" => "$.a", "exists" => true }] })), base(s))
    assert_result "failed", outcome
    assert_equal ["warning: step 1 (GET /x): header Vary is missing", "error: step 1 (GET /x): $.a selects nothing, expected a value"],
                 messages_text(outcome)
  end

  test "content_type compares the media type without parameters, case-insensitively" do
    s = server { [200, { "Content-Type" => "Application/JSON; charset=UTF-8" }, "{}"] }
    assert_result "passed", run_check(check(get("/x", { "content_type" => "application/json" })), base(s))
    s = server { [200, { "Content-Type" => "application/problem+json" }, "{}"] }
    assert_result "failed", run_check(check(get("/x", { "content_type" => "application/json" })), base(s))
    assert_result "passed", run_check(check(get("/x", { "content_type" => "application/problem+json" })), base(s))
  end

  test "content_type of a JSON type needs a body that parses as JSON; any JSON value is accepted in http" do
    s = server { |r| r.path.end_with?("bad") ? json(200, "{not json") : json(200, r.path.end_with?("bare") ? "42" : "\"text\"") }
    outcome = run_check(check(get("/bad", { "content_type" => "application/json" })), base(s))
    assert_equal ["error: step 1 (GET /bad): the body is not valid JSON"], messages_text(outcome)
    assert_result "passed", run_check(check(get("/bare", { "content_type" => "application/json" })), base(s))
    assert_result "passed", run_check(check(get("/string", { "content_type" => "application/json" })), base(s))
  end

  test "header assertions: missing field, fields with the same name, case of names" do
    s = server(protocols: %w[http/1.1]) { [200, { "vary" => %w[Origin Accept], "Cache-Control" => "no-store" }, ""] }
    steps = get("/x", { "status" => [200], "headers" => [
      { "name" => "VARY", "equals" => "Origin, Accept" },
      { "name" => "Vary", "contains" => "accept" },
      { "name" => "cache-control", "matches" => "^no-store$" },
      { "name" => "X-Missing", "exists" => false }
    ] })
    assert_result "passed", run_check(check(steps), base(s))
    steps = get("/x", { "headers" => [{ "name" => "X-Missing", "equals" => "a" }, { "name" => "X-Missing", "exists" => true, "severity" => "warning" }] })
    outcome = run_check(check(steps), base(s))
    assert_equal ['error: step 1 (GET /x): header X-Missing is missing, expected exactly "a"',
                  "warning: step 1 (GET /x): header X-Missing is missing"], messages_text(outcome)
  end

  test "matches on values that are not strings fails, even if their text would match" do
    s = server { json(200, { "n" => 42, "b" => true, "s" => "42" }) }
    outcome = run_check(check(get("/x", { "json" => [{ "path" => "$.n", "matches" => "42" }, { "path" => "$.b", "matches" => "true" },
                                                     { "path" => "$.s", "matches" => "^42$" }] })), base(s))
    assert_equal ["error: step 1 (GET /x): $.n is 42, expected a string matching /42/",
                  "error: step 1 (GET /x): $.b is true, expected a string matching /true/"], messages_text(outcome)
  end

  test "ECMA-262 ^ and $ with a line break in the value" do
    s = server { json(200, { "v" => "first\nsecond" }) }
    assert_result "failed", run_check(check(get("/x", { "json" => [{ "path" => "$.v", "matches" => "^second" }] })), base(s))
    assert_result "passed", run_check(check(get("/x", { "json" => [{ "path" => "$.v", "matches" => "^first\\nsecond$" }] })), base(s))
  end

  test "I-Regexp in match() and search() inside the JSONPath" do
    s = server { json(200, { "ids" => ["urn:pcds:1", "Battery-7"] }) }
    assert_result "passed", run_check(check(get("/x", { "json" => [{ "path" => "$.ids[?search(@, 'pcds')]", "exists" => true },
                                                                    { "path" => "$.ids[?match(@, '[Bb]attery-\\\\p{Nd}')]", "exists" => true }] })), base(s))
    assert_result "failed", run_check(check(get("/x", { "json" => [{ "path" => "$.ids[?match(@, 'pcds')]", "exists" => true }] })), base(s))
  end

  test "unusable patterns skip the criterion before any request" do
    s = server { json(200, {}) }
    cases = {
      "invalid ECMA-262 in matches" => check(get("/x", { "json" => [{ "path" => "$.a", "matches" => "(" }] })),
      "lookahead in matches" => check(get("/x", { "json" => [{ "path" => "$.a", "matches" => "a(?=b)" }] })),
      "header matches outside the subset" => check(get("/x", { "headers" => [{ "name" => "Vary", "matches" => "(?<n>A)" }] })),
      "^ in search()" => check(get("/x", { "json" => [{ "path" => "$.a[?search(@, '^x')]", "exists" => true }] })),
      "invalid I-Regexp in match()" => check(get("/x", { "json" => [{ "path" => "$.a[?match(@, '\\\\d')]", "exists" => true }] })),
      "base_matches not valid" => check(get("/x", { "status" => [200] }), base_matches: "v1)"),
      "unusable pattern in a later step" => check(get("/x", { "status" => [200] }), get("/y", { "json" => [{ "path" => "$.a", "matches" => "\\1" }] }))
    }
    cases.each do |name, c|
      outcome = run_check(c, base(s))
      assert_equal "skipped", outcome.result, name
      assert_match(/regular expression/, outcome.reason, name)
    end
    assert_empty s.received, "no request may be sent for a skipped criterion"
  end

  test "a placeholder outside a string literal of a JSONPath skips the criterion before any request" do
    s = server { json(200, {}) }
    outcome = run_check(check(get("/x", { "json" => [{ "path" => "$.a[{dppId}]", "exists" => true }] })), base(s))
    assert_equal "skipped", outcome.result
    assert_match(/outside a string literal/, outcome.reason)
    assert_empty s.received
  end

  test "base_matches is searched in the API base" do
    s = server { json(200, {}) }
    assert_result "passed", run_check(check(get("/x", { "status" => [200] }), base_matches: "/v1/?$"), base(s))
    outcome = run_check(check(get("/x", { "status" => [200] }), base_matches: "/v2/?$"), base(s))
    assert_result "failed", outcome
    assert_match(/does not match/, messages_text(outcome).first)
  end

  test "skip_if_status skips, warn_if_status warns without evaluating expect" do
    s = server { |r| r.path.include?("skip") ? json(401, {}) : json(400, {}) }
    outcome = run_check(check(get("/skip", { "status" => [200] }, skip_if_status: [401, 403])), base(s))
    assert_result "skipped", outcome
    assert_match(/401 is listed in skip_if_status/, outcome.reason)
    outcome = run_check(check(get("/warn", { "status" => [200], "json" => [{ "path" => "$.x", "exists" => true }] }, warn_if_status: [400])), base(s))
    assert_result "warning", outcome
    assert_equal ["warning: step 1 (GET /warn): HTTP status 400 is listed in warn_if_status"], messages_text(outcome)
  end

  test "skip_if_status after a failed step fails the criterion; after passed or warned steps it skips" do
    s = server { |r| r.path.end_with?("/ok") ? json(200, {}) : json(r.path.end_with?("/bad") ? 500 : 401, {}) }
    later = get("/date", { "status" => [200] }, skip_if_status: [401])
    outcome = run_check(check(get("/bad", { "status" => [200] }), later, get("/never", { "status" => [200] })), base(s))
    assert_result "failed", outcome
    assert_equal ["error: step 1 (GET /bad): HTTP status is 500, expected 200"], messages_text(outcome)
    assert_match(/listed in skip_if_status; an earlier step failed/, outcome.details.join("\n"))
    refute_includes s.received.map(&:path), "/dpp/v1/never"
    outcome = run_check(check(get("/ok", { "status" => [200], "json" => [{ "path" => "$.x", "exists" => true, "severity" => "warning" }] }), later), base(s))
    assert_result "skipped", outcome
    assert_match(/401 is listed in skip_if_status/, outcome.reason)
  end

  test "severity warning on a step turns its failures into warnings; error is the default" do
    s = server { json(500, {}) }
    assert_result "warning", run_check(check(get("/x", { "status" => [200] }, severity: "warning")), base(s))
    assert_result "failed", run_check(check(get("/x", { "status" => [200] }, severity: "error")), base(s))
    assert_result "failed", run_check(check(get("/x", { "status" => [200] }, severity: "warning"), get("/y", { "status" => [200] })), base(s))
  end

  test "request bodies: strings as they are, other values as JSON with placeholders" do
    s = server(protocols: %w[http/1.1]) { json(400, {}) }
    post = lambda do |body, headers = nil|
      request = { "method" => "POST", "path" => "/dppsByProductIds", "auth" => "none", "body" => body }
      request["headers"] = headers if headers
      { "request" => request, "expect" => { "status" => [400] } }
    end
    run_check(check(post.call("{not json", { "Content-Type" => "application/json" }), post.call(["{productId}"]), post.call({ "productId" => 42 })), base(s))
    bodies = s.received.map { |r| [r.body, r.headers["content-type"]] }
    assert_equal [["{not json", ["application/json"]], [JSON.generate([PRODUCT_ID]), ["application/json"]], ['{"productId":42}', ["application/json"]]], bodies
  end

  test "body_equals_step compares with the body of an earlier step" do
    count = 0
    s = server { |r| count += 1 if r.path.end_with?("changing"); json(200, { "n" => count }) }
    assert_result "passed", run_check(check(get("/a", { "status" => [200] }), get("/a", { "status" => [200], "body_equals_step" => 1 })), base(s))
    outcome = run_check(check(get("/changing", { "status" => [200] }), get("/changing", { "status" => [200], "body_equals_step" => 1 })), base(s))
    assert_result "failed", outcome
    assert_match(/body differs from the body of step 1/, messages_text(outcome).first)
  end

  test "DPP-API-015 form: ID found in a bare array or a wrapping object, not in a nested array only" do
    step = { "request" => { "method" => "POST", "path" => "/dppsByProductIds", "auth" => "none", "headers" => { "Content-Type" => "application/json" }, "body" => ["{productId}"] },
             "expect" => { "status" => [200], "content_type" => "application/json", "json" => [{ "path" => "$..[?@ == '{dppId}']", "exists" => true }] },
             "warn_if_status" => [400] }
    [[DPP_ID], { "dppIds" => [DPP_ID] }, { "results" => [{ "productId" => PRODUCT_ID, "dppId" => DPP_ID }] }].each do |body|
      s = server { json(200, body) }
      assert_result "passed", run_check(check(step), base(s))
    end
    s = server { json(200, { "dppIds" => ["did:oyd:other"] }) }
    assert_result "failed", run_check(check(step), base(s))
  end

  test "missing test data or credentials skip the criterion" do
    s = server { json(200, {}) }
    outcome = run_check(check(get("/dpps/{dppId}/elements/{elementIdPath}", { "status" => [200] })), base(s), test_data: { "elementIdPath" => nil })
    assert_result "skipped", outcome
    assert_match(/no value for \{elementIdPath\}/, outcome.reason)
    token = { "request" => { "method" => "PATCH", "path" => "/dpps/{dppId}", "auth" => "token" }, "expect" => { "status" => [200] } }
    assert_match(/credentials/, run_check(check(token), base(s)).reason)
    assert_empty s.received
  end

  test "a service that is not reachable is skipped, a TLS failure fails" do
    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.addr[1]
    tcp.close
    outcome = run_check(check(get("/x", { "status" => [200] })), "https://127.0.0.1:#{port}/dpp/v1")
    assert_result "skipped", outcome
    assert_match(/not reachable/, outcome.reason)
    s = server(cert: :self_signed) { json(200, {}) }
    outcome = run_check(check(get("/x", { "status" => [200] })), base(s))
    assert_result "failed", outcome
    assert_match(/no response: certificate not valid/, messages_text(outcome).first)
  end
end
