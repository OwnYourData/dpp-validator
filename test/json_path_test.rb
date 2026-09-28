require_relative "test_helper"

class JsonPathTest < ValidatorTestCase
  JP = DppValidator::JsonPath

  test "RFC 9535 selection" do
    doc = { "a" => { "b" => [1, 2, 3] }, "digitalProductPassportId" => "did:x" }
    assert_equal ["did:x"], JP.select("$.digitalProductPassportId", doc)
    assert_equal [2, 3], JP.select("$.a.b[?@ > 1]", doc)
    assert_equal [], JP.select("$.missing", doc)
    assert_equal [5], JP.select("$", 5)
  end

  test "a bare @ compares the current value, also for arrays (janeway 1.1.0 patched)" do
    assert_equal ["did:x"], JP.select("$..[?@ == 'did:x']", { "dppIds" => ["did:x"] })
    assert_equal ["did:x"], JP.select("$..[?@ == 'did:x']", ["did:x", "other"])
    assert_equal ["did:x"], JP.select("$..[?@ == 'did:x']", { "list" => [{ "dppId" => "did:x" }, "y", ["z", "w"]] })
    assert_equal [2, 3], JP.select("$[?@ > 1]", [[5], 2, 3])
    assert_equal [[1, 2], "ab"], JP.select("$[?length(@) == 2]", [[1, 2], "ab", 3])
  end

  test "match() needs the whole value, search() a substring, both as I-Regexp" do
    doc = { "t" => ["battery", "Battery", "x\nbat", "BAT", 5] }
    assert_equal ["battery", "x\nbat"], JP.select("$.t[?search(@, 'bat')]", doc)
    assert_equal ["battery"], JP.select("$.t[?match(@, 'batt.*')]", doc)
    assert_equal ["battery", "Battery"], JP.select("$.t[?match(@, '[Bb]attery')]", doc)
    assert_equal [], JP.select("$.t[?match(@, 'bat')]", doc)
  end

  test "I-Regexp: . does not match line breaks, no \\d, category escapes exist" do
    doc = { "t" => ["a\nb", "a b", "123"] }
    assert_equal ["a b"], JP.select("$.t[?match(@, 'a.b')]", doc)
    assert_equal ["123"], JP.select("$.t[?match(@, '\\\\p{Nd}+')]", doc)
  end

  test "match() and search() on values that are not strings are false" do
    assert_equal [], JP.select("$[?search(@, '5')]", [5, true, nil, [5], { "a" => "5" }])
  end

  test "unusable patterns in match() and search() are reported before evaluation" do
    assert_nil JP.problem("$.t[?search(@, '[Bb]atter')]")
    assert_match(/contains \^ outside a character class/, JP.problem("$.t[?search(@, '^bat')]"))
    assert_match(/contains \$ outside a character class/, JP.problem("$.t[?match(@, 'bat$')]"))
    assert_match(/is not a valid I-Regexp/, JP.problem("$.t[?search(@, '\\\\d+')]"))
    assert_match(/is not a valid I-Regexp/, JP.problem("$.t[?search(@, 'a*?')]"))
    assert_match(/contains \$/, JP.problem("$.a[?match(@.x, 'a')].b[?search(@, 'b$')]"))
    assert_match(/contains \^/, JP.problem("$.a[?(@.n > 1 && search(@.s, '^x'))]"))
    assert_nil JP.problem("$.t[?search(@, '[^a]')]")
  end

  test "an invalid JSONPath is reported" do
    assert_match(/is not valid RFC 9535/, JP.problem("$["))
    assert_match(/is not valid RFC 9535/, JP.problem("$.a[?@ =~ 'x']"))
  end
end
