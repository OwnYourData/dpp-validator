require_relative "test_helper"

# The wording lives in config/funding.yml. The result pages write it into their
# footer; the README carries a copy that `rake funding:write` rewrites.
class FundingTest < ValidatorTestCase
  test "names this component, the project and the grant" do
    md = DppValidator::Funding.markdown
    assert md.start_with?("The DPP Service Validator is part of [PACE-DPP](https://dpp-austria.at/) – Promoting and Accelerating"), md
    assert_includes md, "under grant number [917177](https://projekte.ffg.at/projekt/5128301)"
    assert md.end_with?("supported by the German Research Promotion Agency (DLR-PT)."), md
  end

  test "turns the links into anchors for the footer and leaves out the title" do
    html = DppValidator::Funding.html
    assert html.start_with?('The DPP Service Validator is part of <a href="https://dpp-austria.at/">PACE-DPP</a>. This Lighthouse Project'), html
    assert_includes html, '(<a href="https://www.bmimi.gv.at/en.html">BMIMI</a>, formerly BMK)'
    assert_includes html, '<a href="https://projekte.ffg.at/projekt/5128301">917177</a>'
    refute_includes html, "Promoting and Accelerating"
    refute_includes html, "]("
  end

  test "keeps the Funding section of the README as the configuration says, before the licence" do
    content = File.read(DppValidator::Funding::README, encoding: "UTF-8")
    assert_equal DppValidator::Funding.markdown, DppValidator::Funding.current,
                 "README differs from config/funding.yml: run bundle exec rake funding:write"
    assert content.index("## Funding") < content.index("## License")
  end
end
