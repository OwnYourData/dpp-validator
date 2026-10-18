require "fileutils"

module DppValidator
  # One scheduled round of checks (dpp-validator cycle --cadence ...):
  #
  # - daily: every operator entry (check.mode full-daily) is run in full, and
  #   its example passports are checked with dpplint;
  # - weekly: every research entry with check.mode read-only-weekly is run
  #   read-only, every research entry with check.mode test-instance-weekly is
  #   run in full on our own test instance, and the example passports of all
  #   research entries are checked with dpplint, whether the service itself is
  #   checked or not.
  #
  # A test instance is started before the cycle (test-instances/<id>/instance.sh
  # start); its info file <test_instances_dir>/<id>.json gives the API base,
  # the test passport and the software version. Without that file the entry
  # is reported as an error and not run.
  #
  # Results go to <output>/<id>.json (dpp-validator) and
  # <output>/linter/<id>.json (dpplint). Services are handled one after the
  # other; an error with one entry is reported and does not stop the others.
  class Cycle
    CADENCES = %w[daily weekly].freeze

    def initialize(repository:, cadence:, output_dir:, linter: Linter.new, config_for: ->(read_only) { Config.new(read_only: read_only) },
                   out: $stdout, now: Time.now.utc, test_instances_dir: nil)
      raise Error, "unknown cadence #{cadence} (daily or weekly)" unless CADENCES.include?(cadence)

      @repository = repository
      @cadence = cadence
      @output_dir = output_dir
      @linter = linter
      @config_for = config_for
      @out = out
      @now = now
      @test_instances_dir = test_instances_dir
    end

    # Returns { runs: [ids], lints: [ids], errors: [messages] }.
    def call
      done = { runs: [], lints: [], errors: [] }
      entries.each do |service|
        if service.test_instance?
          run_test_instance(service, done)
        elsif service.checked?
          run_service(service, done)
        end
        lint_service(service, done) if service.example_passports.any?
      end
      done
    end

    def entries
      @repository.services.select { |s| s.cadence == @cadence }
    end

    private

    def run_service(service, done)
      config = @config_for.call(service.read_only?)
      report = Runner.new(repository: @repository, service: service, config: config, now: @now).run
      write(File.join(@output_dir, "#{service.id}.json"), report.to_json)
      @out.puts report.to_text.lines.first(4).join
      done[:runs] << service.id
    rescue StandardError => e
      done[:errors] << "#{service.id}: #{e.class}: #{e.message}"
      @out.puts "error in the run of #{service.id}: #{e.message}"
    end

    def run_test_instance(service, done)
      path = File.join(@test_instances_dir.to_s, "#{service.id}.json")
      unless @test_instances_dir && File.file?(path)
        done[:errors] << "#{service.id}: test instance not available (no #{path})"
        @out.puts "test instance of #{service.id} not available, not run"
        return
      end

      info = JSON.parse(File.read(path))
      config = @config_for.call(false).tap { |c| c.test_instance = info }
      report = Runner.new(repository: @repository, service: service.on_test_instance(info), config: config, now: @now).run
      write(File.join(@output_dir, "#{service.id}.json"), report.to_json)
      @out.puts report.to_text.lines.first(4).join
      done[:runs] << service.id
    rescue StandardError => e
      done[:errors] << "#{service.id}: #{e.class}: #{e.message}"
      @out.puts "error in the run of #{service.id}: #{e.message}"
    end

    def lint_service(service, done)
      result = @linter.run(service)
      write(File.join(@output_dir, "linter", "#{service.id}.json"), JSON.pretty_generate(result))
      result["passports"].each do |p|
        @out.puts "dpplint #{service.id} #{p['label']}: #{p.dig('summary', 'text') || p['error']}"
      end
      done[:lints] << service.id
    rescue StandardError => e
      done[:errors] << "#{service.id} (dpplint): #{e.class}: #{e.message}"
      @out.puts "error in the dpplint check of #{service.id}: #{e.message}"
    end

    def write(path, text)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{text.chomp}\n")
    end
  end
end
