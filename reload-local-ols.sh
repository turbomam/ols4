#!/usr/bin/env bash
# Reliable local OLS4 reload for a SINGLE ontology config.
#
# Usage:
#   ./reload-local-ols.sh dataload/configs/mixs-mainfix.json
#
# Why this script exists: the OLS4 local load has several non-obvious traps (documented in
# LOCAL_OLS_LOAD.md). This encodes the working sequence so we stop rediscovering them.
#
# After it finishes: frontend http://localhost:8083/ontologies/mixs , backend :8082 .
set -Eeuo pipefail

CFG="${1:?usage: reload-local-ols.sh <dataload/configs/NAME.json>}"
PROJ=ols4mixs
export HOST_UID; HOST_UID=$(id -u)
export HOST_GID; HOST_GID=$(id -g)
cd "$(dirname "$0")"

pg_has_ols4() {
  # postgres socket lands in /tmp OR /var/run/postgresql depending on init; try both.
  docker exec "${PROJ}-ols4-postgres-1" sh -c \
    'psql -U postgres -h /tmp -lqt 2>/dev/null || psql -U postgres -h /var/run/postgresql -lqt 2>/dev/null' \
    2>/dev/null | cut -d'|' -f1 | grep -qw ols4
}

echo "[1/6] ensure docker daemon is up"
if ! docker info >/dev/null 2>&1; then
  open -a Docker
  until docker info >/dev/null 2>&1; do sleep 3; done
fi

echo "[2/6] tear down + clean state (avoids nextflow cache + stale clusters)"
docker compose -p "$PROJ" down 2>/dev/null || true
rm -rf out tmp/work tmp/NXF_CACHE_DIR

echo "[3/6] dataload -> builds out/postgres.tgz (this is the populated cluster)"
OLS4_CONFIG="$CFG" ./dataload.sh

echo "[4/6] materialize a REAL postgres data dir from the tarball"
# out/postgres is a SYMLINK into tmp/work; the real cluster is only inside out/postgres.tgz.
test -s out/postgres.tgz || { echo "ERROR: out/postgres.tgz missing/empty - dataload failed"; exit 1; }
rm -rf out/postgres; mkdir -p out/postgres
tar -xzf out/postgres.tgz -C out/postgres   # creates out/postgres/data with the ols4 cluster
chmod 700 out/postgres/data
# sanity: a user database (OID >= 16384) must exist beyond template0/1/postgres (1,4,5)
if ! ls out/postgres/data/base | grep -qvE '^(1|4|5|pgsql_tmp)$'; then
  echo "ERROR: extracted cluster has no user database (ols4 was not built)"; exit 1
fi

echo "[5/6] start postgres with --force-recreate"
# MUST force-recreate: Docker resolves the bind-mount symlink at container-create time, so a
# container created while out/postgres was still a symlink will keep mounting the stale path.
docker compose -p "$PROJ" up -d --force-recreate ols4-postgres
echo -n "  waiting for ols4 db "
for _ in $(seq 1 30); do if pg_has_ols4; then echo " ok"; break; fi; echo -n "."; sleep 5; done
pg_has_ols4 || { echo; echo "ERROR: ols4 db never appeared"; docker logs "${PROJ}-ols4-postgres-1" | tail -20; exit 1; }

echo "[6/6] start backend + frontend with --no-deps"
# --no-deps is REQUIRED: the postgres healthcheck (pg_isready -h /tmp) is a false-unhealthy
# under the non-root HOST_UID run, so backend's depends_on: service_healthy would never release.
docker compose -p "$PROJ" up -d --no-deps ols4-backend ols4-frontend
echo -n "  waiting for backend "
for _ in $(seq 1 24); do
  code=$(curl -s -m5 -o /dev/null -w "%{http_code}" http://localhost:8082/api/v2/ontologies/mixs 2>/dev/null || true)
  [ "$code" = "200" ] && { echo " ok"; break; }; echo -n "."; sleep 10
done

echo
echo "DONE. Browse: http://localhost:8083/ontologies/mixs"
echo "Verify roots: curl -s 'http://localhost:8082/api/v2/ontologies/mixs/classes?isPreferredRoot=true' | python3 -m json.tool"
