require "json_schemer"
require "open3"

module DppValidator
  # A checkout of dpp-criteria at a fixed commit. Criteria and service
  # entries are read at run time, never copied into this repository. Every
  # file is checked against the JSON Schemas of the same checkout; a criterion
  # that does not match is skipped with the schema errors as reason.
  class CriteriaRepository
    Criterion = Struct.new(:data, :file, :schema_errors, keyword_init: true) do
      def [](key) = data[key]
      def id = data["id"]
    end

    attr_reader :dir

    def initialize(dir)
      @dir = File.expand_path(dir)
      return if File.directory?(File.join(@dir, "criteria")) && File.file?(schema_path("criterion"))

      raise Error, "#{@dir} is not a dpp-criteria checkout (criteria/ or schema/criterion.schema.json missing)"
    end

    # Full commit hash of the checkout: the file COMMIT (written when the
    # Docker image is built) or `git rev-parse HEAD`; "-dirty" is appended if
    # git reports local changes (git runs without optional locks, so that it
    # never writes into the checkout).
    def commit
      @commit ||= begin
        file = File.join(@dir, "COMMIT")
        if File.file?(file)
          File.read(file).strip
        else
          head, ok = git("rev-parse", "HEAD")
          if ok
            changes, listed = git("status", "--porcelain")
            listed && !changes.strip.empty? ? "#{head.strip}-dirty" : head.strip
          else
            "unknown"
          end
        end
      end
    end

    def criteria
      @criteria ||= Dir[File.join(@dir, "criteria", "**", "*.yaml")].sort.map do |file|
        data = load_yaml(file)
        Criterion.new(data: data, file: relative(file), schema_errors: errors(criterion_schema, data))
      end
    end

    # A service entry by id (services/<id>.yaml) or by path.
    def service(id_or_path)
      file = File.file?(id_or_path.to_s) ? id_or_path : File.join(@dir, "services", "#{id_or_path}.yaml")
      raise Error, "no service entry #{id_or_path} in #{relative(File.join(@dir, 'services'))}" unless File.file?(file)

      data = load_yaml(file)
      problems = errors(service_schema, data)
      raise Error, "service entry #{file} does not match schema/service.schema.json: #{problems.join('; ')}" if problems.any?

      Service.new(data)
    end

    def service_ids = Dir[File.join(@dir, "services", "*.yaml")].map { |f| File.basename(f, ".yaml") }.sort

    private

    def schema_path(name) = File.join(@dir, "schema", "#{name}.schema.json")
    def criterion_schema = @criterion_schema ||= JSONSchemer.schema(JSON.parse(File.read(schema_path("criterion"))), format: false)
    def service_schema = @service_schema ||= JSONSchemer.schema(JSON.parse(File.read(schema_path("service"))), format: false)

    # YAML to plain JSON values (dates become strings, as in the schema).
    def load_yaml(file)
      JSON.parse(JSON.generate(YAML.safe_load(File.read(file), permitted_classes: [Date])))
    end

    def errors(schema, data)
      schema.validate(data).map { |e| e['error'] }.uniq.first(10)
    end

    def relative(path) = path.delete_prefix("#{@dir}/")

    def git(*args)
      out, status = Open3.capture2e("git", "--no-optional-locks", "-c", "safe.directory=*", "-C", @dir, *args)
      [out, status.success?]
    rescue SystemCallError
      ["", false]
    end
  end
end
