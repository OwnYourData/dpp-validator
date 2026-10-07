require_relative "test_helper"

class PlaceholdersTest < ValidatorTestCase
  def placeholders
    DppValidator::Placeholders.new("base" => "https://x.example/dpp/v1", "dppId" => "did:oyd:zQm1",
                                   "productId" => "https://example.org/01/1?x=y", "elementIdPath" => "$.a['b c']",
                                   "randomId" => "dpp-validator-missing", "now" => "2026-09-28T12:00:00Z")
  end

  test "values in a request path are percent-encoded, the text around them is kept" do
    p = placeholders
    assert_equal "/dpps/did%3Aoyd%3AzQm1", p.expand_path("/dpps/{dppId}")
    assert_equal "/dppsByProductId/https%3A%2F%2Fexample.org%2F01%2F1%3Fx%3Dy", p.expand_path("/dppsByProductId/{productId}")
    assert_equal "/dpps/did%3Aoyd%3AzQm1/elements/%24.a%5B%27b%20c%27%5D", p.expand_path("/dpps/{dppId}/elements/{elementIdPath}")
    assert_equal "/dpps/did%3Aoyd%3AzQm1/elements/%24%5B", p.expand_path("/dpps/{dppId}/elements/%24%5B")
    assert_equal "/dppsByIdAndDate/did%3Aoyd%3AzQm1?date=2026-09-28T12%3A00%3A00Z", p.expand_path("/dppsByIdAndDate/{dppId}?date={now}")
  end

  test "values in headers, bodies and expected values are inserted as they are" do
    p = placeholders
    assert_equal ["https://example.org/01/1?x=y"], p.expand(["{productId}"])
    assert_equal({ "id" => "did:oyd:zQm1", "n" => 42 }, p.expand({ "id" => "{dppId}", "n" => 42 }))
  end

  test "values in JSONPath string literals are escaped for the literal" do
    p = DppValidator::Placeholders.new("dppId" => "it's \\ \"q\"\n")
    assert_equal "$..[?@ == 'it\\'s \\\\ \"q\"\\u000A']", p.expand_json_path("$..[?@ == '{dppId}']")
    assert_equal "$..[?@ == \"it's \\\\ \\\"q\\\"\\u000A\"]", p.expand_json_path("$..[?@ == \"{dppId}\"]")
    assert_equal "$..[?@ == 'did:oyd:zQm1']", placeholders.expand_json_path("$..[?@ == '{dppId}']")
  end

  test "an escaped value is valid RFC 9535 and compared literally" do
    value = "it's \\ \"q\"\n"
    p = DppValidator::Placeholders.new("dppId" => value)
    %w[' "].each do |q|
      path = p.expand_json_path("$..[?@ == #{q}{dppId}#{q}]")
      assert_nil DppValidator::JsonPath.problem(path), path
      assert_equal [value], DppValidator::JsonPath.select(path, { "a" => [value, "other"] }), path
    end
  end

  test "escaped quotes in the criterion do not end the literal" do
    p = placeholders
    assert_equal "$['a\\'b', 'did:oyd:zQm1']", p.expand_json_path("$['a\\'b', '{dppId}']")
  end

  test "a placeholder outside a string literal makes the JSONPath unusable" do
    assert_raises(DppValidator::Placeholders::Unusable) { placeholders.expand_json_path("{elementIdPath}") }
    assert_raises(DppValidator::Placeholders::Unusable) { placeholders.expand_json_path("$['a'].{dppId}") }
  end

  test "only the placeholder names of CRITERIA-FORMAT.md are replaced" do
    assert_equal "{not json", placeholders.expand("{not json")
    assert_equal "{other}", placeholders.expand_path("{other}")
  end

  test "missing values are reported, not replaced by empty text" do
    p = DppValidator::Placeholders.new("dppId" => "x", "elementIdPath" => "")
    assert_equal ["elementIdPath"], p.missing({ "path" => "/dpps/{dppId}/elements/{elementIdPath}" })
    assert_raises(DppValidator::Placeholders::Missing) { p.expand_path("/{elementIdPath}") }
  end

  test "now is the run time in ISO 8601 UTC, randomId is fixed per run" do
    service = service_for("https://localhost/dpp/v1")
    p = DppValidator::Placeholders.for(service, now: Time.utc(2026, 9, 28, 12, 0, 0))
    assert_equal "2026-09-28T12:00:00Z", p.values["now"]
    assert_match(/\Adpp-validator-\h{32}\z/, p.values["randomId"])
    assert_equal p.expand("{randomId}"), p.expand("{randomId}")
  end
end
