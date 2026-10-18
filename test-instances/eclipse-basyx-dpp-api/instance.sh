#!/bin/sh
# Test instance of the Eclipse BaSyx DPP API (MIT), for the weekly run:
#
#   instance.sh start <info file>  starts the current release (the highest
#                                  version tag vX.Y.Z of
#                                  eclipse-basyx/basyx-go-components, or
#                                  BASYX_VERSION if set), creates the sample
#                                  passport of that release with POST /v1/dpps
#                                  and writes the info file
#   instance.sh stop               discards containers and volumes
#
# Needs docker with compose, git, curl and jq.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
project=dpp-test-eclipse-basyx-dpp-api
repo=eclipse-basyx/basyx-go-components
network=dpp-validator-test
local_url=http://127.0.0.1:18080
nameplate=https://admin-shell-io/idta/digitalproductpassport/Nameplate/1

compose() { docker compose -p "$project" -f "$here/compose.yaml" "$@"; }

case "${1:-}" in
start)
  [ -n "${2:-}" ] || { echo "usage: instance.sh start <info file>" >&2; exit 2; }
  info=$2
  if [ -z "${BASYX_VERSION:-}" ]; then
    BASYX_VERSION=$(git ls-remote --tags --refs "https://github.com/$repo.git" 'v*' | sed 's#.*refs/tags/v##' |
      grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
    [ -n "$BASYX_VERSION" ] || { echo "no release tag vX.Y.Z found in $repo" >&2; exit 1; }
  fi
  tag=v$BASYX_VERSION
  BASYX_DB_PASSWORD=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  export BASYX_VERSION BASYX_DB_PASSWORD
  echo "Eclipse BaSyx DPP API $BASYX_VERSION"

  docker network inspect "$network" >/dev/null 2>&1 || docker network create "$network" >/dev/null
  compose up -d --quiet-pull
  i=0
  until curl -fsS "$local_url/health" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le 90 ] || { echo "the DPP API did not become ready" >&2; compose logs --tail 50 >&2; exit 1; }
    sleep 2
  done

  work=$(mktemp -d)
  sample="https://raw.githubusercontent.com/$repo/$tag/examples/BaSyxDPPAPIExample/sample-dpp.json"
  curl -fsSL "$sample" -o "$work/sample-dpp.json"
  status=$(curl -sS -o "$work/created.json" -w '%{http_code}' -H 'Content-Type: application/json' \
    --data @"$work/sample-dpp.json" "$local_url/v1/dpps")
  [ "$status" = 201 ] || { echo "POST /v1/dpps answered $status" >&2; cat "$work/created.json" >&2; exit 1; }
  # The checks ask for the passport as of the start of the run ({now}, whole
  # seconds); the passport has to exist by then.
  sleep 2

  element_path=""
  if jq -e --arg n "$nameplate" '.[$n].ManufacturerName != null' "$work/sample-dpp.json" >/dev/null; then
    element_path="\$['$nameplate']['ManufacturerName']"
  fi
  digest() { d=$(docker image inspect --format '{{index .RepoDigests 0}}' "$1") && echo "$1@${d#*@}"; }
  jq -n \
    --arg version "$BASYX_VERSION" \
    --arg release "https://github.com/$repo/releases/tag/$tag" \
    --arg api "$(digest "eclipsebasyx/dppapi-go:$BASYX_VERSION")" \
    --arg conf "$(digest "eclipsebasyx/basyxconfigurationservice-go:$BASYX_VERSION")" \
    --arg db "$(digest postgres:18)" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sample "$sample" \
    --arg element_path "$element_path" \
    --slurpfile passport "$work/sample-dpp.json" \
    '{
      service_id: "eclipse-basyx-dpp-api",
      software: "Eclipse BaSyx DPP API",
      version: $version,
      release: $release,
      images: [$api, $conf, $db],
      started_at: $started,
      setup: "https://github.com/OwnYourData/dpp-validator/tree/main/test-instances/eclipse-basyx-dpp-api",
      test_passport: $sample,
      api_base: "http://basyx-dpp-api:8080/v1",
      test_data: ({
        productId: $passport[0].uniqueProductIdentifier,
        dppId: $passport[0].digitalProductPassportId
      } + (if $element_path == "" then {} else { elementIdPath: $element_path } end))
    }' > "$info"
  rm -rf "$work"
  echo "test passport $(jq -r .test_data.dppId "$info"), info in $info"
  ;;
stop)
  BASYX_VERSION=unused BASYX_DB_PASSWORD=unused compose down -v --remove-orphans
  ;;
*)
  echo "usage: instance.sh start <info file> | stop" >&2
  exit 2
  ;;
esac
