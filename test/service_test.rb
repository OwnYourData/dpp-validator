require_relative "test_helper"

class ServiceTest < ValidatorTestCase
  test "operator entries are checked in full every day" do
    s = DppValidator::Service.new(CriteriaDir.operator("https://api.example/v1"))
    refute s.research?
    assert s.checked?
    refute s.read_only?
    assert_equal "daily", s.cadence
    assert_equal({ "source" => "operator", "as_of" => "2026-10-18" }, s.to_h["entry"])
    assert_equal "AT", s.to_h["country"]
  end

  test "research entries are checked read-only every week, or not at all" do
    weekly = DppValidator::Service.new(CriteriaDir.research({ "mode" => "read-only-weekly" }, "api_base" => "https://api.example/v1"))
    assert weekly.research?
    assert weekly.read_only?
    assert_equal "weekly", weekly.cadence
    none = DppValidator::Service.new(CriteriaDir.research({ "mode" => "none", "reason" => "no_public_instance" }))
    refute none.checked?
    assert_equal "no_public_instance", none.check_reason
    assert_equal "weekly", none.cadence
    assert_equal({ "mode" => "none", "reason" => "no_public_instance" }, none.to_h["check"])
  end
end
