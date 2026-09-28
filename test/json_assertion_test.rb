require_relative "test_helper"

class JsonAssertionTest < ValidatorTestCase
  def messages(assertion, doc) = DppValidator::JsonAssertion.new(assertion).messages(doc)
  def holds?(assertion, doc) = messages(assertion, doc).empty?

  test "exists true and false" do
    assert holds?({ "path" => "$.message", "exists" => true }, { "message" => "x" })
    assert holds?({ "path" => "$.message", "exists" => true }, { "message" => nil })
    refute holds?({ "path" => "$.message", "exists" => true }, {})
    assert holds?({ "path" => "$.message", "exists" => false }, {})
    refute holds?({ "path" => "$.message", "exists" => false }, { "message" => "x" })
  end

  test "equals compares JSON values" do
    assert holds?({ "path" => "$.n", "equals" => 1 }, { "n" => 1.0 })
    assert holds?({ "path" => "$.o", "equals" => { "b" => 2, "a" => 1 } }, { "o" => { "a" => 1, "b" => 2 } })
    refute holds?({ "path" => "$.n", "equals" => "1" }, { "n" => 1 })
    assert_equal ["$.id selects nothing, expected \"x\""], messages({ "path" => "$.id", "equals" => "x" }, {}).map { |m| m[:message] }
  end

  test "in holds if the value is one of the list" do
    assert holds?({ "path" => "$.s", "in" => %w[Active Inactive] }, { "s" => "Active" })
    refute holds?({ "path" => "$.s", "in" => %w[Active Inactive] }, { "s" => "active" })
  end

  test "matches holds only for JSON strings, other values are not converted" do
    assertion = { "path" => "$.v", "matches" => "42" }
    assert holds?(assertion, { "v" => "id-42" })
    [42, 42.0, true, nil, ["42"], { "a" => "42" }].each do |value|
      refute holds?(assertion, { "v" => value }), value.inspect
    end
    refute holds?({ "path" => "$.v", "matches" => "true" }, { "v" => true })
    refute holds?({ "path" => "$.v", "matches" => "null" }, { "v" => nil })
  end

  test "matches: ECMA-262 search without implicit anchoring, ^ and $ anchor the whole value" do
    doc = { "v" => "first\nsecond" }
    assert holds?({ "path" => "$.v", "matches" => "cond" }, doc)
    refute holds?({ "path" => "$.v", "matches" => "^second" }, doc)
    refute holds?({ "path" => "$.v", "matches" => "first$" }, doc)
    assert holds?({ "path" => "$.v", "matches" => "^first\\nsecond$" }, doc)
    refute holds?({ "path" => "$.v", "matches" => "Second" }, doc)
  end

  test "severity warning" do
    assert_equal ["warning"], messages({ "path" => "$.message", "exists" => true, "severity" => "warning" }, {}).map { |m| m[:severity] }
    assert_equal ["error"], messages({ "path" => "$.message", "exists" => true }, {}).map { |m| m[:severity] }
  end

  test "problem: unusable ECMA-262 patterns and JSONPath" do
    assert_nil DppValidator::JsonAssertion.new({ "path" => "$.a", "matches" => "^a$" }).problem
    assert_match(/not a valid ECMA-262/, DppValidator::JsonAssertion.new({ "path" => "$.a", "matches" => "(" }).problem)
    assert_match(/outside the portable subset/, DppValidator::JsonAssertion.new({ "path" => "$.a", "matches" => "(?<=a)b" }).problem)
    assert_match(/I-Regexp/, DppValidator::JsonAssertion.new({ "path" => "$[?search(@, '\\\\w')]", "exists" => true }).problem)
  end
end
