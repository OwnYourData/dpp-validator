require "janeway"

module DppValidator
  # RFC 9535 JSONPath, evaluated with the janeway-jsonpath gem.
  #
  # CRITERIA-FORMAT.md ("Regular expressions") requires the patterns of the
  # functions match() and search() to be I-Regexp (RFC 9485) without `^` or
  # `$`. janeway translates them into Ruby regular expressions on its own,
  # which is not the same dialect (in Ruby `^` and `$` are line anchors, `\d`
  # and lazy quantifiers exist, ...). Both functions are therefore evaluated
  # with IRegexp (copied from dpplint), and `problem` checks every literal
  # pattern before the JSONPath is used: an unusable pattern makes the
  # criterion skipped instead of letting the function return false.
  module JsonPath
    class Invalid < DppValidator::Error; end

    # Replaces janeway's regex translation for match() and search().
    module IRegexpFunctions
      def build_regex_body(parameters, anchor:)
        method = anchor ? :match? : :search?
        literal = parameters[1].is_a?(Janeway::AST::StringType) ? parameters[1].value : nil
        if literal
          ->(str, _pattern) { IRegexp.public_send(method, literal, str) }
        else
          ->(str, pattern) { pattern.is_a?(String) && IRegexp.public_send(method, pattern, str) }
        end
      end
    end
    Janeway::Functions.singleton_class.prepend(IRegexpFunctions)

    # janeway-jsonpath 1.1.0 returns a bare `@` as the current value itself
    # instead of a node list with that value. In a comparison an array value
    # is then taken for a node list: `$..[?@ == 'x']` selects ["x"] as well as
    # "x", and raises for arrays with several members. RFC 9535 (2.3.5.2.2)
    # compares the value of the current node. This patch does so for
    # comparisons with a bare `@` and leaves everything else to janeway.
    module BareCurrentNodeComparison
      def initialize(operator)
        super
        @bare_left = bare_current_node?(operator.left)
        @bare_right = bare_current_node?(operator.right)
      end

      def interpret(input, parent, root, path = nil)
        return super unless @extract_single_value && (@bare_left || @bare_right)

        lhs = @bare_left ? input : to_single_value(@left.interpret(input, parent, root, []))
        rhs = @bare_right ? input : to_single_value(@right.interpret(input, parent, root, []))
        @op.call(lhs, rhs)
      end

      private

      def bare_current_node?(node) = node.is_a?(Janeway::AST::CurrentNode) && node.empty?
    end
    Janeway::Interpreters::BinaryOperatorInterpreter.prepend(BareCurrentNodeComparison)

    module_function

    # The values (nodelist) the query selects in the document.
    def select(path, document)
      parse(path).enum_for(document).search
    end

    # nil if the path can be evaluated, otherwise the reason.
    def problem(path)
      query = parse(path)
      functions(query.root).each do |function|
        pattern = function.parameters[1]
        next unless pattern.is_a?(Janeway::AST::StringType)

        reason = IRegexp.problem(pattern.value)
        return "regular expression #{pattern.value.inspect} of #{function.name}() in JSONPath #{path} #{reason}" if reason
      end
      nil
    rescue Invalid => e
      e.message
    end

    def parse(path)
      Janeway.parse(path.to_s)
    rescue Janeway::Error, ArgumentError => e
      raise Invalid, "JSONPath #{path} is not valid RFC 9535 (#{e.message})"
    end

    # All match() and search() calls in the syntax tree.
    def functions(node, seen = {}.compare_by_identity)
      return [] if node.nil? || seen[node]

      seen[node] = true
      found = []
      if node.is_a?(Janeway::AST::Function) && %w[match search].include?(node.name)
        found << node
      end
      children = case node
                 when Array then node
                 when Janeway::AST::Expression, Janeway::Query
                   node.instance_variables.map { |v| node.instance_variable_get(v) }
                 else []
                 end
      children.each { |child| found.concat(functions(child, seen)) }
      found
    end
  end
end
