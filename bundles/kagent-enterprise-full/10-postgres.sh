#!/usr/bin/env bash
# One PostgreSQL server for Substrate and kagent.
#
# Neither chart deploys PostgreSQL. Each reads two connection strings from Secrets made
# beforehand, and each login runs `SET ROLE` to a group role on every connection, so the logins,
# roles, schemas and grants all exist before 20-substrate.sh and 30-kagent.sh run:
#
#   database   login                      role it assumes      schemas
#   substrate  substrate_owner_user       substrate_owner      substrate (owner)
#              substrate_readwrite_user   substrate_readwrite  substrate (read/write)
#   kagent     kagent_owner_user          kagent_owner         kagent, enterprise (owner)
#              kagent_readwrite_user      kagent_readwrite     kagent, enterprise (read/write)
#
# The owner login applies migrations at startup; the read/write login serves every runtime
# query. Each side runs the product's own setup SQL, vendored unchanged in helpers/postgres/:
# substrate's pkg/postgressetup/setup.sql, community kagent's go/core/pkg/postgressetup/setup.sql,
# and enterprise kagent's migrations/postgres/setup/setup.sql. The role names are the charts'
# defaults, so 30-kagent.sh doesn't have to name them.
#
# Passwords are generated once and kept in Secret postgres-logins, so a re-apply keeps them.
# Plain passwords over a cluster-internal Service with sslmode=disable.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/helpers/env.sh"
CTX="${CONTEXT:?CONTEXT not set — solomog sets this for bundle hooks}"
k() { kubectl --context "$CTX" "$@"; }
good() { printf '    ✓ %s\n' "$*"; }
PG_IMAGE="${KEF_PG_IMAGE:-pgvector/pgvector:pg17}"

echo "==> PostgreSQL ${PG_IMAGE} → ${PG_NS} (databases substrate and kagent)"
for ns in "$PG_NS" "$KAGENT_NS"; do
  k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
done

LOGINS="postgres substrate_owner_user substrate_readwrite_user kagent_owner_user kagent_readwrite_user"
k get secret postgres-logins -n "$PG_NS" >/dev/null 2>&1 || k create secret generic postgres-logins -n "$PG_NS" >/dev/null
for u in $LOGINS; do
  if [ -z "$(k get secret postgres-logins -n "$PG_NS" -o jsonpath="{.data.${u}}")" ]; then
    k patch secret postgres-logins -n "$PG_NS" --type merge \
      -p "{\"data\":{\"${u}\":\"$(openssl rand -hex 24 | tr -d '\n' | base64)\"}}" >/dev/null
  fi
done
pw() { k get secret postgres-logins -n "$PG_NS" -o jsonpath="{.data.$1}" | base64 -d; }

k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata: {name: postgres, namespace: ${PG_NS}, labels: {app: postgres}}
spec:
  selector: {app: postgres}
  ports: [{name: postgres, port: 5432, targetPort: 5432}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: postgres, namespace: ${PG_NS}, labels: {app: postgres}}
spec:
  serviceName: postgres
  replicas: 1
  selector: {matchLabels: {app: postgres}}
  template:
    metadata: {labels: {app: postgres}}
    spec:
      containers:
      - name: postgres
        image: ${PG_IMAGE}
        args: ["-c", "max_connections=200"]
        env:
        - {name: POSTGRES_PASSWORD, valueFrom: {secretKeyRef: {name: postgres-logins, key: postgres}}}
        - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
        ports: [{containerPort: 5432}]
        readinessProbe: {exec: {command: [pg_isready, -U, postgres]}, periodSeconds: 5}
        resources:
          requests: {cpu: 250m, memory: 512Mi}
          limits: {memory: 2Gi}
        volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
  volumeClaimTemplates:
  - metadata: {name: data}
    spec:
      accessModes: [ReadWriteOnce]
      resources: {requests: {storage: 5Gi}}
EOF
k rollout status statefulset/postgres -n "$PG_NS" --timeout=300s >/dev/null
good "postgres-0 ready"

psql_in() {   # psql_in DB [psql args…] → runs SQL from stdin as the superuser, in one transaction
  local db="$1"; shift
  k exec -i -n "$PG_NS" postgres-0 -c postgres -- \
    psql --no-psqlrc --set=ON_ERROR_STOP=1 --single-transaction -q -U postgres -d "$db" "$@" >/dev/null
}
mkdb() {
  [ "$(k exec -n "$PG_NS" postgres-0 -c postgres -- psql -U postgres -Atc "select 1 from pg_database where datname='$1'")" = 1 ] \
    || k exec -n "$PG_NS" postgres-0 -c postgres -- psql -q -U postgres -c "create database $1" >/dev/null
}
dsn() { printf 'postgres://%s:%s@%s:5432/%s?sslmode=disable' "$1" "$(pw "$1")" "$PG_HOST" "$2"; }
secret() {    # secret NAMESPACE NAME KEY VALUE
  k create secret generic "$2" -n "$1" --from-literal="$3=$4" --dry-run=client -o yaml | k apply -f - >/dev/null
}

mkdb substrate
psql_in substrate \
  --set=substrate_schema=substrate \
  --set=substrate_owner_role=substrate_owner \
  --set=substrate_owner_user=substrate_owner_user \
  --set=substrate_owner_password="$(pw substrate_owner_user)" \
  --set=substrate_readwrite_role=substrate_readwrite \
  --set=substrate_readwrite_user=substrate_readwrite_user \
  --set=substrate_readwrite_password="$(pw substrate_readwrite_user)" \
  < "$HERE/helpers/postgres/substrate-setup.sql"
secret "$SUBSTRATE_NS" substrate-postgres-owner ownerConnectionString "$(dsn substrate_owner_user substrate)"
secret "$SUBSTRATE_NS" substrate-postgres-readwrite readWriteConnectionString "$(dsn substrate_readwrite_user substrate)"
good "substrate: Secrets substrate-postgres-owner and -readwrite in ${SUBSTRATE_NS}"

mkdb kagent
psql_in kagent \
  --set=kagent_schema=kagent \
  --set=kagent_owner_role=kagent_owner \
  --set=kagent_owner_user=kagent_owner_user \
  --set=kagent_owner_password="$(pw kagent_owner_user)" \
  --set=kagent_readwrite_role=kagent_readwrite \
  --set=kagent_readwrite_user=kagent_readwrite_user \
  --set=kagent_readwrite_password="$(pw kagent_readwrite_user)" \
  < "$HERE/helpers/postgres/kagent-setup.sql"
# agentevals_user empty: no agentevals login until phase 2 turns agentevals on.
psql_in kagent \
  --set=kagent_owner_role=kagent_owner \
  --set=kagent_readwrite_role=kagent_readwrite \
  --set=enterprise_schema=enterprise \
  --set=agentevals_user= \
  < "$HERE/helpers/postgres/kagent-enterprise-setup.sql"
secret "$KAGENT_NS" kagent-postgres-owner ownerConnectionString "$(dsn kagent_owner_user kagent)"
secret "$KAGENT_NS" kagent-postgres-readwrite readWriteConnectionString "$(dsn kagent_readwrite_user kagent)"
good "kagent: schemas kagent and enterprise; Secrets kagent-postgres-owner and -readwrite in ${KAGENT_NS}"
