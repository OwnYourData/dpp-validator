require "optparse"
require "fileutils"

module DppValidator
  # dpp-validator run --service <id or file> [--criteria DIR] [--output FILE] [--read-only] [--test-instance FILE]
  # dpp-validator cycle --cadence daily|weekly [--criteria DIR] [--output DIR] [--dpplint URL] [--test-instances DIR] [--history DIR]
  # dpp-validator services [--criteria DIR] [--cadence daily|weekly | --test-instances]
  # dpp-validator site --results DIR --output DIR [--criteria DIR] [--this-service ID] [--site-url URL]
  # dpp-validator version
  class Cli
    USAGE = <<~TEXT.freeze
      Usage:
        dpp-validator run --service <id|file> [--criteria DIR] [--output FILE|-] [--read-only] [--test-instance FILE]
        dpp-validator cycle --cadence daily|weekly [--criteria DIR] [--output DIR] [--dpplint URL] [--test-instances DIR] [--history DIR]
        dpp-validator services [--criteria DIR] [--cadence daily|weekly | --test-instances]
        dpp-validator site --results DIR --output DIR [--criteria DIR] [--this-service ID] [--site-url URL]
        dpp-validator version

      --criteria      dpp-criteria checkout (default: $DPP_CRITERIA_DIR or /opt/dpp-criteria)
      --output        run: JSON result file (default: results/<service id>.json; "-" for stdout)
                      cycle: directory for <id>.json and linter/<id>.json (default: out)
                      site: directory for the result pages and available-services.json
      --results       site: directory with the JSON results (<id>.json, linter/<id>.json)
      --read-only     run: send only GET, HEAD and OPTIONS; criteria with other
                      methods are skipped (reason_code not_sent). Entries from
                      our research (entry.source research) are always run read-only,
                      except on our own test instance.
      --test-instance run: info file of the running test instance of an entry with
                      check.mode test-instance-weekly (written by
                      test-instances/<id>/instance.sh start); the run is in full
      --test-instances cycle: directory with the info files <id>.json of the
                      started test instances; services: list the entries that
                      are checked on our own test instance
      --cadence       daily: operator entries, run in full, and their example
                      passports; weekly: research entries, run read-only or on
                      our own test instance, and their example passports.
                      services: list the entries whose service is run with that
                      cadence.
      --dpplint       cycle: base URL of dpplint (default: #{Linter::DEFAULT_URL})
      --history       cycle: directory runs/ of the stored results (branch
                      results); passport criteria with check.history, such
                      as DPP-ID-002, are rated from it. Without it dpplint's
                      result (skipped) stays.
      --this-service  site: id of the entry marked "this_service" in available-services.json
      --site-url      site: base URL of the published pages (default: #{Site::DEFAULT_SITE_URL})
    TEXT

    def initialize(argv, out: $stdout, err: $stderr, config: Config.new, linter_config: Config.new(read_timeout: 120))
      @argv = argv.dup
      @out = out
      @err = err
      @config = config
      @linter_config = linter_config
    end

    # Exit status: 0 if the run completed (whatever its results), 1 if a cycle
    # had errors with single entries, 2 on usage or configuration errors.
    def call
      command = @argv.shift
      options = parse_options
      case command
      when "run" then run(options)
      when "cycle" then cycle(options)
      when "services" then services(options)
      when "site" then site(options)
      when "version" then version(options)
      else
        @err.puts USAGE
        2
      end
    rescue OptionParser::ParseError, DppValidator::Error => e
      @err.puts "dpp-validator: #{e.message}"
      2
    end

    private

    def parse_options
      options = { criteria: ENV.fetch("DPP_CRITERIA_DIR", "/opt/dpp-criteria") }
      OptionParser.new do |o|
        o.on("--service VALUE") { |v| options[:service] = v }
        o.on("--criteria DIR") { |v| options[:criteria] = v }
        o.on("--output FILE") { |v| options[:output] = v }
        o.on("--results DIR") { |v| options[:results] = v }
        o.on("--read-only") { options[:read_only] = true }
        o.on("--test-instance FILE") { |v| options[:test_instance] = v }
        o.on("--test-instances [DIR]") { |v| options[:test_instances] = v || true }
        o.on("--cadence VALUE") { |v| options[:cadence] = v }
        o.on("--dpplint URL") { |v| options[:dpplint] = v }
        o.on("--history DIR") { |v| options[:history] = v }
        o.on("--this-service ID") { |v| options[:this_service] = v }
        o.on("--site-url URL") { |v| options[:site_url] = v }
      end.parse!(@argv)
      options
    end

    def run(options)
      raise DppValidator::Error, "--service is required" unless options[:service]

      repository = CriteriaRepository.new(options[:criteria])
      service = repository.service(options[:service])
      unless service.checked?
        raise DppValidator::Error, "#{service.id} is not checked (check.mode none, reason #{service.check_reason})"
      end

      if service.test_instance?
        raise DppValidator::Error, "#{service.id} is checked on our own test instance: --test-instance FILE is required" unless options[:test_instance]
        raise DppValidator::Error, "--read-only does not apply to a run on a test instance" if options[:read_only]

        info = begin
          JSON.parse(File.read(options[:test_instance]))
        rescue SystemCallError, JSON::ParserError => e
          raise DppValidator::Error, "test instance info #{options[:test_instance]}: #{e.message}"
        end
        @config.test_instance = info
        service = service.on_test_instance(info)
      else
        @config.read_only = true if options[:read_only] || service.research?
      end
      report = Runner.new(repository: repository, service: service, config: @config).run
      output = options[:output] || File.join("results", "#{service.id}.json")
      if output == "-"
        @out.puts report.to_json
      else
        FileUtils.mkdir_p(File.dirname(output))
        File.write(output, "#{report.to_json}\n")
        @out.puts report.to_text
        @out.puts "JSON result: #{output}"
      end
      0
    end

    def cycle(options)
      raise DppValidator::Error, "--cadence daily or --cadence weekly is required" unless options[:cadence]
      raise DppValidator::Error, "--history #{options[:history]} is not a directory" if options[:history] && !File.directory?(options[:history])

      repository = CriteriaRepository.new(options[:criteria])
      linter = Linter.new(base_url: options[:dpplint] || Linter::DEFAULT_URL, config: @linter_config)
      config_for = lambda do |read_only|
        @config.dup.tap { |c| c.read_only = read_only }
      end
      dir = options[:test_instances].is_a?(String) ? options[:test_instances] : nil
      done = Cycle.new(repository: repository, cadence: options[:cadence], output_dir: options[:output] || "out",
                       linter: linter, config_for: config_for, out: @out, test_instances_dir: dir,
                       history_dir: options[:history]).call
      @out.puts "#{options[:cadence]}: #{done[:runs].size} service run(s), #{done[:lints].size} dpplint check(s), #{done[:errors].size} error(s)"
      done[:errors].each { |e| @err.puts "dpp-validator: #{e}" }
      done[:errors].empty? ? 0 : 1
    end

    def site(options)
      raise DppValidator::Error, "--results and --output are required" unless options[:results] && options[:output]

      services = File.directory?(File.join(options[:criteria].to_s, "services")) ? CriteriaRepository.new(options[:criteria]).services : nil
      count = Site.new(results_dir: options[:results], output_dir: options[:output], services: services,
                       site_url: options[:site_url] || Site::DEFAULT_SITE_URL, this_service: options[:this_service]).build
      @out.puts "#{count} service(s) written to #{File.join(options[:output], 'index.html')} and available-services.json"
      0
    end

    def services(options)
      repository = CriteriaRepository.new(options[:criteria])
      ids = if options[:test_instances]
              repository.services.select(&:test_instance?).map(&:id)
            elsif options[:cadence]
              raise DppValidator::Error, "unknown cadence #{options[:cadence]}" unless Cycle::CADENCES.include?(options[:cadence])

              repository.services.select { |s| s.checked? && s.cadence == options[:cadence] }.map(&:id)
            else
              repository.service_ids
            end
      @out.puts ids
      0
    end

    def version(options)
      commit = begin
        CriteriaRepository.new(options[:criteria]).commit
      rescue DppValidator::Error
        "not available"
      end
      @out.puts "dpp-validator #{VERSION}, dpp-criteria #{commit}"
      0
    end
  end
end
