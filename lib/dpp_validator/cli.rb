require "optparse"
require "fileutils"

module DppValidator
  # dpp-validator run --service <id or file> [--criteria DIR] [--output FILE]
  # dpp-validator services [--criteria DIR]
  # dpp-validator version
  class Cli
    USAGE = <<~TEXT.freeze
      Usage:
        dpp-validator run --service <id|file> [--criteria DIR] [--output FILE|-]
        dpp-validator services [--criteria DIR]
        dpp-validator version

      --criteria  dpp-criteria checkout (default: $DPP_CRITERIA_DIR or /opt/dpp-criteria)
      --output    JSON result file (default: results/<service id>.json; "-" for stdout)
    TEXT

    def initialize(argv, out: $stdout, err: $stderr, config: Config.new)
      @argv = argv.dup
      @out = out
      @err = err
      @config = config
    end

    # Exit status: 0 if the run completed (whatever its results), 2 on usage
    # or configuration errors.
    def call
      command = @argv.shift
      options = parse_options
      case command
      when "run" then run(options)
      when "services" then services(options)
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
      end.parse!(@argv)
      options
    end

    def run(options)
      raise DppValidator::Error, "--service is required" unless options[:service]

      repository = CriteriaRepository.new(options[:criteria])
      service = repository.service(options[:service])
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

    def services(options)
      @out.puts CriteriaRepository.new(options[:criteria]).service_ids
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
