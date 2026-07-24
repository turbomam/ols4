# Loading an ontology into the local OLS4 Docker (the reliable way)

This documents how to load a single OWL file into the local OLS4 stack and view it, and the
non-obvious traps that cost real time. Use `./reload-local-ols.sh <config.json>` for the
whole sequence; this file explains what it does and why.

Endpoints once running: frontend `http://localhost:8083/ontologies/mixs`, backend API
`http://localhost:8082/api/v2/...`. Compose project name: `ols4mixs`.

## TL;DR

```bash
# 1. put your OWL in the repo root, e.g. mixs_mainfix.owl.ttl
# 2. make a config in dataload/configs/<name>.json (see "Config" below)
./reload-local-ols.sh dataload/configs/mixs-mainfix.json
# 3. open http://localhost:8083/ontologies/mixs
```

## Architecture (what actually happens)

- `dataload.sh` runs a Nextflow pipeline (in Docker) that turns the OWL into JSON/TSV, then
  `load_into_postgres.py` **initdb's a fresh PostgreSQL cluster, `createdb ols4`, bulk-loads
  it, stops postgres cleanly, and tars the cluster to `out/postgres.tgz`**. The DB name is
  hard-coded `ols4` (load_into_postgres.py).
- The `ols4-backend` (Spring) connects to that postgres (`OLS_POSTGRES_DB=ols4`) and serves
  the v2 API; `ols4-frontend` serves the UI. There is no Solr/Neo4j in this build; postgres
  is the store.
- `docker-compose.yml` bind-mounts `./out/postgres/data` into the postgres container.

## The traps (each cost time; the script handles them)

1. **`out/postgres` is a symlink into `tmp/work/<hash>/postgres`, and the real cluster is
   only inside `out/postgres.tgz`.** After a dataload, `out/postgres/data` may be empty (or
   the symlinked work dir), so the postgres container init's a fresh empty cluster (only
   `postgres`/`template0`/`template1`, no `ols4`) and the backend dies with
   `FATAL: database "ols4" does not exist`. **Fix:** extract `out/postgres.tgz` into a real
   `out/postgres/data` before starting postgres.

2. **Docker resolves bind-mount symlinks at container-create time.** If the postgres
   container was first created while `out/postgres` was still a symlink, it keeps mounting
   that stale resolved path even after you replace `out/postgres` with a real dir. Tell-tale:
   `out/postgres/data/base` (host) shows `16384` but `docker exec ... ls .../data/base` does
   not. **Fix:** `docker compose down` (or `up --force-recreate ols4-postgres`) AFTER
   extracting, so the mount re-resolves to the real directory.

3. **The postgres healthcheck is a false `unhealthy` under the non-root `HOST_UID` run.**
   The compose runs postgres as `${HOST_UID}:${HOST_GID}`, so its socket lands in
   `/var/run/postgresql`, but the healthcheck probes `pg_isready -h /tmp`. It reports
   `unhealthy` even though the DB is accepting connections, and the backend's
   `depends_on: { ols4-postgres: { condition: service_healthy } }` never releases. **Fix:**
   start the app tier with `--no-deps`: `docker compose up -d --no-deps ols4-backend ols4-frontend`.

4. **The postgres socket path varies** between `/tmp` and `/var/run/postgresql` depending on
   how the cluster was initialized. When `psql`-ing via `docker exec`, try both `-h /tmp` and
   `-h /var/run/postgresql` (the script does).

5. **`out/` entries are symlinks; `du` reports 0B.** Use `ls -laL` / `tar -tzf` to inspect
   real sizes/contents. A healthy `out/postgres.tgz` is ~10+ MB and contains `data/base/16384/`
   (the `ols4` DB; OID >= 16384 means a user database beyond the 1/4/5 system DBs).

6. **`relation "ontology" does not exist` is NOT an error.** OLS4 stores ontology data under
   its own schema/tables, not a table literally named `ontology`. Use it only as a "wrong DB"
   probe, not a data check.

## Reliable sequence (what the script runs)

```bash
export HOST_UID=$(id -u) HOST_GID=$(id -g)
docker info >/dev/null 2>&1 || { open -a Docker; until docker info >/dev/null 2>&1; do sleep 3; done; }
docker compose -p ols4mixs down
rm -rf out tmp/work tmp/NXF_CACHE_DIR                       # clean state (avoid nextflow cache reuse)
OLS4_CONFIG=./dataload/configs/<name>.json ./dataload.sh    # builds out/postgres.tgz
rm -rf out/postgres && mkdir -p out/postgres
tar -xzf out/postgres.tgz -C out/postgres                  # real out/postgres/data with ols4
chmod 700 out/postgres/data
docker compose -p ols4mixs up -d --force-recreate ols4-postgres
docker compose -p ols4mixs up -d --no-deps ols4-backend ols4-frontend
```

## Config (dataload/configs/<name>.json)

Point `ontology_purl` at a local file and set the preferred roots. Example used for the
LinkML grouping fix (`mixs-mainfix.json`):

```json
{
  "ontologies": [{
    "id": "mixs",
    "preferredPrefix": "MIXS",
    "ontology_purl": "file:///Users/mam/gitrepos/ols4-mixs/mixs_mainfix.owl.ttl",
    "base_uri": ["https://w3id.org/mixs/"],
    "label_property": ["http://www.w3.org/2000/01/rdf-schema#label", "http://purl.org/dc/terms/title"],
    "definition_property": ["http://www.w3.org/2004/02/skos/core#definition"],
    "preferred_root_term": [
      "https://w3id.org/mixs/Checklist",
      "https://w3id.org/mixs/Extension",
      "https://w3id.org/linkml/EnumDefinition"
    ],
    "reasoner": "OWL2"
  }]
}
```

## Verify it loaded

```bash
# ols4 db exists
docker exec ols4mixs-ols4-postgres-1 psql -U postgres -h /tmp -lqt | cut -d'|' -f1   # (or -h /var/run/postgresql)
# backend serving
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8082/api/v2/ontologies/mixs   # 200
# grouping renders (the point of the linkml fix): expect 3 roots incl. enum_definition
curl -s 'http://localhost:8082/api/v2/ontologies/mixs/classes?isPreferredRoot=true' | python3 -m json.tool
```

## Context: the linkml OWL-generation fix this was used to validate

The grouping node renders only when the OWL **declares** `linkml:EnumDefinition` as an
`owl:Class` (with a label). Stock `gen-owl --add-root-classes` referenced it via
`rdfs:subClassOf` but never declared it, so OLS dropped the grouping. The fix is in
linkml worktree `~/gitrepos/linkml-owlfix` (branch `owl-declare-grouping-classes`, for
linkml issue #3605). Generate the OWL with that worktree:

```bash
cd ~/gitrepos/linkml-owlfix
uv run linkml generate owl --add-root-classes <mixs.yaml> > ~/gitrepos/ols4-mixs/mixs_mainfix.owl.ttl 2>/dev/null
```

Note `linkml generate owl -o FILE` prints to stdout instead of writing the file; redirect
with `>` and send stderr (deprecation warnings) to `/dev/null`.
