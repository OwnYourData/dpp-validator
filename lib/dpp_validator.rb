require "json"
require "yaml"
require "date"
require "time"
require "securerandom"
require "openssl"
require "socket"
require "uri"

# dpp-validator runs the service criteria of dpp-criteria against a listed DPP
# service. Results are reported as "N of M automated checks passed"; they are
# no certification and establish no presumption of conformity.
module DppValidator
  class Error < StandardError; end
end

require_relative "dpp_validator/version"
require_relative "dpp_validator/config"
require_relative "dpp_validator/from_dpplint/ecma_regexp"
require_relative "dpp_validator/from_dpplint/i_regexp"
require_relative "dpp_validator/from_dpplint/header_assertion"
require_relative "dpp_validator/messages"
require_relative "dpp_validator/json_path"
require_relative "dpp_validator/json_assertion"
require_relative "dpp_validator/placeholders"
require_relative "dpp_validator/transport/response"
require_relative "dpp_validator/transport/io_deadline"
require_relative "dpp_validator/transport/tls_versions"
require_relative "dpp_validator/transport/ssl3_probe"
require_relative "dpp_validator/transport/http1"
require_relative "dpp_validator/transport/http2"
require_relative "dpp_validator/transport/client"
require_relative "dpp_validator/expectation"
require_relative "dpp_validator/checks"
require_relative "dpp_validator/checks/http_check"
require_relative "dpp_validator/checks/tls_check"
require_relative "dpp_validator/criteria_repository"
require_relative "dpp_validator/service"
require_relative "dpp_validator/runner"
require_relative "dpp_validator/report"
require_relative "dpp_validator/cli"
