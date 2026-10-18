require "tmpdir"
require "fileutils"

# A temporary dpp-criteria checkout for tests: the criteria and schemas of the
# real checkout (DPP_CRITERIA_DIR) with service entries of the test.
module CriteriaDir
  SOURCE = ENV.fetch("DPP_CRITERIA_DIR", "/opt/dpp-criteria")

  module_function

  def available? = File.directory?(File.join(SOURCE, "criteria")) && File.directory?(File.join(SOURCE, "schema"))

  # entries: { "id" => hash }. Yields the directory.
  def with(entries)
    Dir.mktmpdir do |dir|
      %w[criteria schema].each { |d| FileUtils.cp_r(File.join(SOURCE, d), dir) }
      FileUtils.mkdir_p(File.join(dir, "services"))
      entries.each { |id, data| File.write(File.join(dir, "services", "#{id}.yaml"), YAML.dump({ "id" => id }.merge(data))) }
      yield dir
    end
  end

  def operator(api_base, **extra)
    { "name" => "Operator entry", "operator" => { "name" => "Test", "country" => "AT" },
      "entry" => { "source" => "operator", "as_of" => "2026-10-18" }, "licence" => { "text" => "MIT", "spdx" => ["MIT"] },
      "check" => { "mode" => "full-daily" }, "contact" => "test@example.org", "api_base" => api_base,
      "features" => %w[fine-granular-api],
      "test_data" => { "productId" => ValidatorTestCase::PRODUCT_ID, "dppId" => ValidatorTestCase::DPP_ID,
                       "elementIdPath" => "$.ProductIdentification.ModelIdentifier" },
      "credentials" => "none", "listed_since" => "2026-10-18" }.merge(extra.transform_keys(&:to_s))
  end

  def research(check, **extra)
    { "name" => "Research entry", "operator" => { "name" => "Someone" },
      "entry" => { "source" => "research", "as_of" => "2026-10-18" }, "licence" => { "text" => "commercial", "spdx" => [] },
      "check" => check, "listed_since" => "2026-10-18" }.merge(extra.transform_keys(&:to_s))
  end
end
