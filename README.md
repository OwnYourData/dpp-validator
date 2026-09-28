# dpp-validator

Runs the service criteria of [dpp-criteria](https://github.com/OwnYourData/dpp-criteria)
against listed Digital Product Passport (DPP) services and reports
"N of M automated checks passed" per service and run.

Results are results of automated checks only. They are no certification and
do not establish a presumption of conformity.

Passport criteria (a published passport behind a product identifier) are
checked by [dpplint](https://github.com/OwnYourData/dpplint); this repository
covers the behaviour of the DPP service and its API.

## Status: phase 1

- Check types `tls` and `http` for all criteria with `target: service` and
  `method: automated`.
- `automated-auth` and `self-declared` criteria are listed as `skipped` with
  the reason; passport criteria are listed under `not_run`.
- Not yet: daily runs with GitHub Actions, GitHub Pages, history over several
  days (`history`, DPP-ID-002), passport criteria through dpplint.

## How it works

The criteria are not copied into this repository. They are read at run time
from a dpp-criteria checkout at a fixed commit; the Docker image contains the
commit pinned in [`DPP_CRITERIA_REF`](DPP_CRITERIA_REF), and every result names
the commit it was produced with. Criteria and service entries are checked
against the JSON Schemas of the same checkout.

[CRITERIA-FORMAT.md](https://github.com/OwnYourData/dpp-criteria/blob/main/CRITERIA-FORMAT.md)
defines the check types; the comments at the top of each file under
`lib/dpp_validator/checks/` say how this runner applies them. Gaps in the
format are resolved by pull requests to dpp-criteria, not in the runner.

Per criterion the result is `passed`, `warning` (passed, with a remark),
`failed` or `skipped` (with a reason). Only criteria with `status: active`
count in "N of M"; `passed` and `warning` count as passed, `skipped` is not
counted. Criteria with `status: proposed` are reported separately as
"proposed, not counted".

## Usage

```sh
./build.sh
docker run --rm oydeu/dpp-validator:latest test
docker run --rm -v "$PWD/results:/app/results" oydeu/dpp-validator:latest run --service ownyourdata-dpp-service
```

`./build.sh <ref>` builds with another dpp-criteria commit, branch or tag
(resolved to its commit). The JSON result is written to
`results/<service id>.json`; `--output -` prints it instead.

Without Docker (Ruby 3.1 or later, a dpp-criteria checkout next to this one):

```sh
bundle install
DPP_CRITERIA_DIR=../dpp-criteria bundle exec rake test
bin/dpp-validator run --criteria ../dpp-criteria --service ownyourdata-dpp-service
```

The checks need a direct connection to the service: TLS and HTTP version
checks are meaningless behind a proxy that terminates TLS.

## Result format

```json
{
  "validator": { "name": "dpp-validator", "version": "0.1.0" },
  "notice": "Results of automated checks only. ...",
  "service": { "id": "...", "name": "...", "operator": "...", "api_base": "...", "features": [] },
  "run_at": "2026-09-28T12:00:00Z",
  "dpp_criteria": { "repository": "https://github.com/OwnYourData/dpp-criteria", "commit": "<full commit>" },
  "summary": {
    "text": "N of M automated checks passed", "passed": 0, "failed": 0, "warnings": 0, "skipped": 0,
    "proposed_not_counted": { "text": "...", "passed": 0, "failed": 0, "warnings": 0, "skipped": 0 }
  },
  "criteria": [
    { "id": "DPP-API-013", "version": 1, "status": "proposed", "title": "...", "level": "MUST",
      "target": "service", "method": "automated", "check_type": "http", "result": "passed",
      "messages": [], "details": ["step 1 (GET /dpps/{dppId}): HTTP 200 over HTTP/2"], "counted": false }
  ],
  "not_run": [ { "id": "DPP-DAT-014", "target": "passport", "reason": "..." } ]
}
```

`messages` holds failures and warnings (`severity` `error` or `warning`),
`reason` the reason for `skipped`, `details` what the runner observed.

## Layout

- `lib/dpp_validator/checks/` – one class per check type, registered in `checks.rb`
- `lib/dpp_validator/transport/` – HTTP/1.x and HTTP/2 over TLS with ALPN, TLS version probes
- `lib/dpp_validator/from_dpplint/` – `EcmaRegexp`, `IRegexp`, `HeaderAssertion`, copied unchanged from dpplint (source commit in each file header), with their tests under `test/from_dpplint/`
- `test/` – Minitest; local HTTPS test servers with their own CA, HTTP/1.1 and HTTP/2

## Third-party components

[http-2](https://github.com/igrigorik/http-2) (MIT), [janeway-jsonpath](https://github.com/gongfarmer/janeway)
(MIT; `match()`/`search()` and comparisons with a bare `@` are adapted in
`json_path.rb`), [json_schemer](https://github.com/davishmcclurg/json_schemer) (MIT).

## License

Apache License 2.0 – see [LICENSE](LICENSE).
