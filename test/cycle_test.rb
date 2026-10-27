require_relative "test_helper"
require_relative "support/fake_dpp_service"
require "stringio"

class CycleTest < ValidatorTestCase
  def dpplint_server
    server do |_req|
      json(200, { "summary" => { "text" => "1 of 1 automated checks passed", "passed" => 1, "failed" => 0, "warnings" => 0 },
                  "criteria" => [] })
    end
  end

  def cycle(dir, cadence, dpplint, plain, output)
    repository = DppValidator::CriteriaRepository.new(dir)
    linter = DppValidator::Linter.new(base_url: dpplint.url, config: config(read_timeout: 5), now: NOW)
    config_for = ->(read_only) { config(http_port: plain.port, read_only: read_only) }
    DppValidator::Cycle.new(repository: repository, cadence: cadence, output_dir: output, linter: linter,
                            config_for: config_for, out: StringIO.new, now: NOW).call
  end

  test "daily runs operator entries in full and weekly runs research entries read-only" do
    skip "no dpp-criteria checkout at #{CriteriaDir::SOURCE}" unless CriteriaDir.available?
    operator_api = server(protocols: %w[h2], &FakeDppService.handler(DPP_ID, PRODUCT_ID))
    research_api = server(protocols: %w[h2], &FakeDppService.handler(DPP_ID, PRODUCT_ID))
    plain = plain_server { [301, { "Location" => "https://localhost/" }, ""] }
    dpplint = dpplint_server
    entries = {
      "op" => CriteriaDir.operator(operator_api.url("/dpp/v1"),
                                   "example_passports" => [{ "product_id" => "https://op.example/01/1", "label" => "reference" }]),
      "res" => CriteriaDir.research({ "mode" => "read-only-weekly" }, "api_base" => research_api.url("/dpp/v1"),
                                    "test_data" => { "productId" => PRODUCT_ID, "dppId" => DPP_ID }),
      "none" => CriteriaDir.research({ "mode" => "none", "reason" => "needs_credentials" },
                                     "example_passports" => [{ "product_id" => "https://none.example/01/1", "label" => "demo" }])
    }
    CriteriaDir.with(entries) do |dir|
      out = File.join(dir, "out")
      daily = cycle(dir, "daily", dpplint, plain, out)
      assert_equal({ runs: ["op"], lints: ["op"], errors: [] }, daily)
      assert_equal "full", JSON.parse(File.read(File.join(out, "op.json")))["mode"]
      assert_includes operator_api.received.map(&:method), "POST"
      assert_empty research_api.received

      weekly = cycle(dir, "weekly", dpplint, plain, out)
      assert_equal({ runs: ["res"], lints: ["none"], errors: [] }, weekly)
      assert_equal "read-only", JSON.parse(File.read(File.join(out, "res.json")))["mode"]
      assert_equal %w[GET], research_api.received.map(&:method).uniq
      refute File.exist?(File.join(out, "none.json")), "an entry with check.mode none is not run"
      lint = JSON.parse(File.read(File.join(out, "linter", "none.json")))
      assert_equal "1 of 1 automated checks passed", lint["passports"].first.dig("summary", "text")
      assert_equal %w[/api/v1/validate/https://op.example/01/1 /api/v1/validate/https://none.example/01/1],
                   dpplint.received.map(&:path)
    end
  end

  test "with the stored runs, DPP-ID-002 of the example passports is rated from DPP-ID-001" do
    skip "no dpp-criteria checkout at #{CriteriaDir::SOURCE}" unless CriteriaDir.available?
    product_id = "https://op.example/01/1"
    criteria = [{ "id" => "DPP-ID-001", "title" => "Resolves", "status" => "active", "result" => "passed" },
                { "id" => "DPP-ID-002", "title" => "Stays resolvable", "status" => "proposed", "result" => "skipped",
                  "reason_code" => "not_evaluated" }]
    dpplint = server do |_req|
      json(200, { "summary" => { "text" => "1 of 1 automated checks passed", "passed" => 1, "failed" => 0, "warnings" => 0 },
                  "criteria" => criteria })
    end
    operator_api = server(protocols: %w[h2], &FakeDppService.handler(DPP_ID, PRODUCT_ID))
    plain = plain_server { [301, { "Location" => "https://localhost/" }, ""] }
    entries = { "op" => CriteriaDir.operator(operator_api.url("/dpp/v1"),
                                             "example_passports" => [{ "product_id" => product_id, "label" => "reference" }]) }
    CriteriaDir.with(entries) do |dir|
      runs = File.join(dir, "runs")
      [2, 1].each do |days_ago|
        path = File.join(runs, (NOW.to_date - days_ago).iso8601, "linter", "op.json")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.generate("service_id" => "op", "passports" => [{ "product_id" => product_id, "status" => "checked",
                                                                                 "criteria" => criteria }]))
      end
      out = File.join(dir, "out")
      repository = DppValidator::CriteriaRepository.new(dir)
      linter = DppValidator::Linter.new(base_url: dpplint.url, config: config(read_timeout: 5), now: NOW)
      DppValidator::Cycle.new(repository: repository, cadence: "daily", output_dir: out, linter: linter, out: StringIO.new, now: NOW,
                              config_for: ->(read_only) { config(http_port: plain.port, read_only: read_only) },
                              history_dir: runs).call
      rated = JSON.parse(File.read(File.join(out, "linter", "op.json")))["passports"].first["criteria"].find { |c| c["id"] == "DPP-ID-002" }
      assert_equal "passed", rated["result"]
      assert_equal "DPP-ID-001 passed in all 3 runs from 2026-09-26 to 2026-09-28", rated["message"]
    end
  end

  test "an unknown cadence is a configuration error" do
    skip "no dpp-criteria checkout at #{CriteriaDir::SOURCE}" unless CriteriaDir.available?
    CriteriaDir.with({}) do |dir|
      assert_raises(DppValidator::Error) do
        DppValidator::Cycle.new(repository: DppValidator::CriteriaRepository.new(dir), cadence: "hourly", output_dir: dir)
      end
    end
  end
end
