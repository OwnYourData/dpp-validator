#!/bin/sh
# Builds oydeu/dpp-validator with dpp-criteria at a fixed commit.
#   ./build.sh          the commit pinned in the file DPP_CRITERIA_REF
#   ./build.sh <ref>    another commit, branch or tag (resolved to its commit)
set -eu
cd "$(dirname "$0")"
REF="${1:-$(cat DPP_CRITERIA_REF)}"
# A branch or tag is resolved to its commit, so that the Docker build cache
# never reuses a clone of an older dpp-criteria.
RESOLVED=$(git ls-remote https://github.com/OwnYourData/dpp-criteria.git \
  "refs/heads/$REF" "refs/tags/$REF" "refs/tags/$REF^{}" | sort -k2 | tail -n1 | cut -f1)
[ -n "$RESOLVED" ] && REF="$RESOLVED"
echo "dpp-criteria: $REF"
docker build --build-arg DPP_CRITERIA_REF="$REF" -t oydeu/dpp-validator:latest .
