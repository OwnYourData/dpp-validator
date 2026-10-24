# dpp-validator

Runs the service criteria of [dpp-criteria](https://github.com/OwnYourData/dpp-criteria)
against listed Digital Product Passport (DPP) services and reports
"N of M automated checks passed" per service and run.

Results are results of automated checks only. They are no certification and
do not establish a presumption of conformity. dpp-validator is part of a
research project and shares what we currently know; the list of services makes
no claim to be complete and is not a legal assessment.

Passport criteria (a published passport behind a product identifier) are
checked by [dpplint](https://github.com/OwnYourData/dpplint); this repository
covers the behaviour of the DPP service and its API.

## Status

- Check types `tls` and `http` for all criteria with `target: service` and
  `method: automated`. A step with `compare_with_resolved` is not evaluated
  in this version; its criterion is `skipped` with
  `reason_code: not_evaluated`.
- `automated-auth` and `self-declared` criteria are listed as `skipped` with
  the reason and a `reason_code`; passport criteria are listed under `not_run`.
- The self-declarations of an entry (`declarations`) are listed with the
  statement and the link to the evidence as the operator gives them, in the
  JSON result and in a section of their own on the result page, apart from the
  checks. They are not checked and never count as passed.
- Features a service lists under `not_implemented` give `skipped` with
  `reason_code: not_implemented`; features it does not declare at all give
  `not_applicable`.
- Two kinds of entries in `services/` of dpp-criteria (`entry.source`):
  entries maintained by the operator are run in full every day; entries from
  our research are run read-only (only GET, HEAD and OPTIONS) once a week, or
  not at all if `check.mode` is `none`. `--read-only` makes any run read-only;
  criteria with other methods are `skipped` with `reason_code: not_sent`.
- Open software without a public instance (`check.mode: test-instance-weekly`)
  is run in full once a week on a short-lived test instance of our own,
  started with the current release and discarded after the run
  ([test-instances/](test-instances/README.md)). The results name the software
  version; certificate, TLS and HTTP version checks and the criteria the entry
  lists under `test_instance.not_applicable` are `skipped` with
  `reason_code: not_applicable`, because they would describe our test
  environment.
- The example passports of an entry (`example_passports`) are checked with the
  API of [dpplint](https://dpplint.ownyourdata.eu) in the same run as the
  service: daily for operator entries, weekly for research entries, also when
  the service itself is not checked.
- Run with GitHub Actions ([`.github/workflows/daily.yml`](.github/workflows/daily.yml),
  every day at about 04:17 UTC, the weekly checks on Mondays; started by hand
  with the input `weekly` for both): the JSON results are kept on the branch
  `results` (`runs/<date>/`, `latest/`, dpplint results under `linter/`), and
  the result pages and `available-services.json` are published on GitHub
  Pages: <https://ownyourdata.github.io/dpp-validator/>.
- Requests carry the User-Agent
  `dpp-validator/<version> (+https://github.com/OwnYourData/dpp-validator; office@ownyourdata.eu)`
  and go one after the other.
- Not yet: rating over several days (`history`, DPP-ID-002).

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
`failed` or `skipped` (with a reason and a `reason_code`: `not_applicable`,
`not_implemented`, `no_evidence`, `needs_credentials`, `not_sent`,
`unreachable` or `not_evaluated`, see "Results" in CRITERIA-FORMAT.md). Only
criteria with `status: active` count in "N of M"; `passed` and `warning` count
as passed, `skipped` is not counted. Criteria with `status: proposed` are
reported separately as "proposed, not counted".

## Usage

```sh
./build.sh
docker run --rm oydeu/dpp-validator:latest test
docker run --rm -v "$PWD/results:/app/results" oydeu/dpp-validator:latest run --service ownyourdata-dpp-service
```

`run` checks one entry: in full for an operator entry, read-only for an entry
from our research, in full on a running test instance with
`--test-instance <info file>` (see [test-instances/](test-instances/README.md));
an entry with `check.mode: none` is refused. `cycle` does what the scheduled
workflow does for one cadence, with the dpplint checks of the example
passports; `--test-instances <dir>` gives the info files of the started test
instances:

```sh
docker run --rm -v "$PWD/out:/app/out" oydeu/dpp-validator:latest cycle --cadence daily --output out
docker run --rm -v "$PWD/out:/app/out" oydeu/dpp-validator:latest cycle --cadence weekly --output out
```

`services --cadence daily|weekly` lists the entries whose service is run with
that cadence, `services --test-instances` those checked on our own test
instance.

A service that is not listed is checked from a local entry file, read-only:

```sh
docker run --rm -v "$PWD/local:/app/local" oydeu/dpp-validator:latest run --service local/service.yaml --output local/result.json --read-only
```

`docker run --rm -v "$PWD/out:/app/out" -v "$PWD/site:/app/site" oydeu/dpp-validator:latest site --results out --output site --this-service ownyourdata-dpp-service`
writes the result pages from the entries of the dpp-criteria checkout and the
JSON results, as the workflow does: `site/index.html` (overview),
`site/services/<id>.html` (one page per entry), `site/results/`,
`site/linter/` and `site/available-services.json`.

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
  "service": { "id": "...", "name": "...", "operator": "...", "api_base": "...", "features": [], "not_implemented": [] },
  "run_at": "2026-09-28T12:00:00Z",
  "mode": "full",
  "dpp_criteria": { "repository": "https://github.com/OwnYourData/dpp-criteria", "commit": "<full commit>" },
  "summary": {
    "text": "N of M automated checks passed", "passed": 0, "failed": 0, "warnings": 0, "skipped": 0,
    "skipped_by_reason": { "not_applicable": 0 },
    "proposed_not_counted": { "text": "...", "passed": 0, "failed": 0, "warnings": 0, "skipped": 0, "skipped_by_reason": {} }
  },
  "criteria": [
    { "id": "DPP-API-013", "version": 1, "status": "proposed", "title": "...",
      "description_url": "https://github.com/OwnYourData/dpp-criteria/blob/<commit>/criteria/README.md#dpp-api-013", "level": "MUST",
      "target": "service", "method": "automated", "check_type": "http", "result": "passed",
      "messages": [], "details": ["step 1 (GET /dpps/{dppId}): HTTP 200 over HTTP/2"], "counted": false }
  ],
  "declarations": {
    "notice": "Statements of the operator about the service, with a link to its evidence, listed as given. ...",
    "items": [
      { "criterion": "DPP-ACC-015", "title": "...", "status": "proposed",
        "description_url": "https://github.com/OwnYourData/dpp-criteria/blob/<commit>/criteria/README.md#dpp-acc-015",
        "statement": "...", "evidence": "https://..." }
    ]
  },
  "not_run": [ { "id": "DPP-DAT-014", "target": "passport", "reason": "..." } ]
}
```

`messages` holds failures and warnings (`severity` `error` or `warning`),
`reason` and `reason_code` the reason for `skipped`, `details` what the runner
observed. `mode` is `full`, `read-only` or `test-instance`; a run on a test
instance has `test_instance` (`software`, `version`, `release`, `images`,
`started_at`, `setup`, `test_passport`, `test_data`) and no `api_base` in
`service`. `skipped_by_reason` counts the
skipped criteria per `reason_code` (only codes that occur).
`description_url` links to the readable description of the criterion in
`criteria/README.md` of the dpp-criteria commit used; it is absent if that
commit has no such page. `declarations` is present only if the entry has
self-declarations; `title`, `status` and `description_url` of an item come
from its criterion and are absent if the commit used has no such criterion.

## Linter result

`cycle` writes `linter/<id>.json` for every entry with example passports:

```json
{
  "service_id": "ownyourdata-dpp-service",
  "checked_at": "2026-10-18T04:20:00Z",
  "dpplint": "https://dpplint.ownyourdata.eu",
  "passports": [
    { "product_id": "https://...", "label": "reference passport", "lint_url": "https://dpplint.ownyourdata.eu/?productId=...",
      "status": "checked", "dpp_criteria": "<commit>",
      "summary": { "text": "5 of 5 automated checks passed", "passed": 5, "failed": 0, "total": 5, "warnings": 1, "skipped": 1, "proposed_failed": 0 },
      "criteria": [ { "id": "DPP-ID-016", "title": "...", "status": "active", "result": "warning" } ] }
  ]
}
```

`status` is `checked` or `error` (with `error`, e.g. when dpplint cannot be
reached).

## available-services.json

The list of all entries with their latest results, for pages that show it
(e.g. the start page of a DPP service). Entries come in this order: the entry
named with `--this-service`, then operator entries, then entries from our
research, each by name.

```json
{
  "generated_at": "2026-10-18T04:25:00Z",
  "notice": "Results of automated checks only, from a research project ...",
  "counting": "passed: active criteria with result passed or warning; ...",
  "services": [
    {
      "id": "ownyourdata-dpp-service", "name": "OwnYourData DPP Service", "url": "https://dpp-service.ownyourdata.eu/",
      "provider": { "name": "OwnYourData", "country": "AT" },
      "this_service": true,
      "entry": { "source": "operator", "as_of": "2026-10-18" },
      "licence": { "text": "Apache-2.0", "spdx": ["Apache-2.0"] },
      "linter": { "passports": [
        { "product_id": "https://...", "label": "reference passport", "lint_url": "https://dpplint.ownyourdata.eu/?productId=...",
          "summary_text": "5 of 5 automated checks passed", "passed": 5, "total": 5, "failed": 0, "warnings": 1,
          "checked_at": "2026-10-18", "note": null } ] },
      "validator": { "status": "checked", "mode": "full", "cadence": "daily",
                     "details_url": "https://ownyourdata.github.io/dpp-validator/services/ownyourdata-dpp-service.html",
                     "summary_text": "15 of 15 automated checks passed", "passed": 15, "total": 15, "failed": 0,
                     "warnings": 0, "proposed_failed": 1, "checked_at": "2026-10-18" }
    }
  ]
}
```

Counting, for `linter` and `validator` alike: `passed` are the active
criteria with result `passed` or `warning`, `failed` those with result
`failed`, `total` is `passed` + `failed`, and `warnings` says how many of the
passed ones have a warning (they are included in `passed`). Skipped criteria
are not counted. `summary_text` is the text of dpplint or dpp-validator; a page
shows these numbers as "5 of 5 passed · 1 warning".

- `linter.passports` is empty, with `linter.note` "no public example
  passport", if the entry lists none. A passport not checked yet has
  `note: "first check pending"`, one whose check failed the error in `note`;
  both without numbers.
- `validator.status` is `checked`, `pending` (no run yet) or, for an entry
  with `check.mode: none`, its `check.reason`: `needs_credentials`,
  `no_public_instance` or `no_en18222_paths`. `mode` is `full`, `read-only`
  or `test-instance` (in full on our own short-lived test instance; then
  `test_instance` gives `software`, `version` and `release` of the last run),
  `cadence` `daily` or `weekly`.

## Layout

- `lib/dpp_validator/checks/` – one class per check type, registered in `checks.rb`
- `test-instances/` – setups of our own short-lived test instances, one directory per entry
- `lib/dpp_validator/transport/` – HTTP/1.x and HTTP/2 over TLS with ALPN, TLS version probes
- `lib/dpp_validator/from_dpplint/` – `EcmaRegexp`, `IRegexp`, `HeaderAssertion`, copied unchanged from dpplint (source commit in each file header), with their tests under `test/from_dpplint/`
- `test/` – Minitest; local HTTPS test servers with their own CA, HTTP/1.1 and HTTP/2
- `assets/oyd-mark.svg` – the OwnYourData mark next to the title of the result pages, also their icon
- `config/funding.yml` – the funding notice in the footer of the result pages and in this README, the one place where its wording is kept

## Third-party components

[http-2](https://github.com/igrigorik/http-2) (MIT), [janeway-jsonpath](https://github.com/gongfarmer/janeway)
(MIT; `match()`/`search()` and comparisons with a bare `@` are adapted in
`json_path.rb`), [json_schemer](https://github.com/davishmcclurg/json_schemer) (MIT).

## Funding

<!-- funding:begin -->
The DPP Service Validator is part of [PACE-DPP](https://dpp-austria.at/) – Promoting and Accelerating a Digital Product Passport based Data-Service Ecosystem. This Lighthouse Project has been made possible by financial contributions from the Austrian Federal Ministry of Innovation, Mobility and Infrastructure ([BMIMI](https://www.bmimi.gv.at/en.html), formerly BMK), supported by the Austrian Research Promotion Agency (FFG) under grant number [917177](https://projekte.ffg.at/projekt/5128301), as well as from the German Federal Ministry of Research, Technology and Space (BMFTR, formerly BMWK), supported by the German Research Promotion Agency (DLR-PT).
<!-- funding:end -->

## License

Apache License 2.0 – see [LICENSE](LICENSE).
