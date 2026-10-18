# Test instances

Open DPP software without a public instance is checked on a short-lived test
instance of our own: once a week, in the scheduled run of
`.github/workflows/daily.yml`, the current release is started on the GitHub
Actions runner, given a test passport, checked in full and discarded after the
run. Nothing of it stays online. The entry in dpp-criteria has
`check.mode: test-instance-weekly` and describes the configuration
(`test_instance`).

Every test instance has its own directory `test-instances/<service id>/` with
`instance.sh`:

- `instance.sh start <info file>` starts the current release, creates the test
  passport and writes the info file (JSON): `software`, `version`, `release`,
  `images` (with digests), `started_at`, `setup`, `test_passport`, `api_base`
  and `test_data` (`productId`, `dppId`, `elementIdPath`);
- `instance.sh stop` removes the containers and their volumes.

The instance joins the Docker network `dpp-validator-test`; dpp-validator runs
on that network and reaches the instance under the `api_base` of the info
file:

```sh
docker network create dpp-validator-test
test-instances/eclipse-basyx-dpp-api/instance.sh start test-instance-info/eclipse-basyx-dpp-api.json
docker run --rm --network dpp-validator-test -v "$PWD/out:/app/out" -v "$PWD/test-instance-info:/app/test-instance-info" \
  oydeu/dpp-validator:latest run --service eclipse-basyx-dpp-api --test-instance test-instance-info/eclipse-basyx-dpp-api.json --output out/eclipse-basyx-dpp-api.json
test-instances/eclipse-basyx-dpp-api/instance.sh stop
```

The results name the software version and the image digests; the internal
`api_base` is not published. On a test instance, the `tls` criteria
(certificate, TLS and HTTP versions) are `skipped` with `not_applicable`,
because they would measure our test environment rather than the software; so
are the criteria the entry lists under `test_instance.not_applicable`.

| Directory | Software | Licence | Release | Test passport |
|---|---|---|---|---|
| `eclipse-basyx-dpp-api` | [Eclipse BaSyx DPP API](https://github.com/eclipse-basyx/basyx-go-components) | MIT | highest version tag `vX.Y.Z`, Docker images `eclipsebasyx/dppapi-go` and `eclipsebasyx/basyxconfigurationservice-go`, with PostgreSQL | sample passport of the release (`examples/BaSyxDPPAPIExample/sample-dpp.json`), created with `POST /v1/dpps` |

`instance.sh` needs Docker with Compose, git, curl and jq.
