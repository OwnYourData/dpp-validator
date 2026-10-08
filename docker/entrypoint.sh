#!/bin/sh
# docker run oydeu/dpp-validator test                         run the test suite
# docker run oydeu/dpp-validator run --service <id> [...]     run the criteria against a listed service
# docker run oydeu/dpp-validator site --results <dir> --output <dir>   static result pages
# docker run oydeu/dpp-validator services | version
set -e
if [ "${1:-}" = "test" ]; then
  exec bundle exec rake test
fi
exec bin/dpp-validator "$@"
