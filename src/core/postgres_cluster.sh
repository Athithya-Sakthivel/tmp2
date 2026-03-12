#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MANIFEST_DIR="${SCRIPT_DIR}/../manifests/postgres"
readonly ARCHIVE_DIR="src/scripts/archive"
readonly K8S_CLUSTER="${K8S_CLUSTER:-kind}"
readonly CLUSTER_NAME="${CLUSTER_NAME:-app-postgres}"
readonly OPERATOR_MANIFEST="${ARCHIVE_DIR}/cnpg-1.28.1.yaml"
readonly LOG_DIR="${LOG_DIR:-/tmp/postgres-rollout-logs}"
mkdir -p "${MANIFEST_DIR}" "${LOG_DIR}"
LOG_FILE="$(mktemp "${LOG_DIR}/rollout-%Y%m%d_%H%M%S.XXXXXX.log")"
exec > >(tee -a "${LOG_FILE}") 2>&1

declare -A STORAGE_CLASS=( [kind]="local-path" [eks]="gp3" )
declare -A PG_INSTANCES=( [kind]="1" [eks]="3" )
declare -A PG_STORAGE_SIZE=( [kind]="5Gi" [eks]="20Gi" )
declare -A PG_CPU_REQUEST=( [kind]="250m" [eks]="500m" )
declare -A PG_MEMORY_REQUEST=( [kind]="512Mi" [eks]="1Gi" )
declare -A PG_CPU_LIMIT=( [kind]="500m" [eks]="1" )
declare -A PG_MEMORY_LIMIT=( [kind]="1Gi" [eks]="2Gi" )
declare -A OPERATOR_TIMEOUT=( [kind]="120" [eks]="300" )
declare -A CLUSTER_WAIT_TIMEOUT=( [kind]="300" [eks]="900" )

export PG_IMAGE="${PG_IMAGE:-docker.io/athithya5354/postgresql:16.10-minimal-trixie}"
export CNPG_IMAGE="${CNPG_IMAGE:-docker.io/athithya5354/cloudnative-pg:1.28.1}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16}"
SQL_READY_RETRIES="${SQL_READY_RETRIES:-24}"
SQL_READY_SLEEP="${SQL_READY_SLEEP:-5}"
SECRET_WAIT_TIMEOUT="${SECRET_WAIT_TIMEOUT:-180}"

log(){ printf '[%s] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$K8S_CLUSTER" "$*"; }
fatal(){ printf '[ERROR] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; echo "primary log: ${LOG_FILE}"; echo "diagnostics: ${LOG_DIR}"; exit 1; }
require_bin(){ command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }
rand(){ printf '%s' "$(date +%s)-$RANDOM"; }

render_manifests(){
  log "rendering manifests for K8S_CLUSTER=${K8S_CLUSTER}"
  mkdir -p "${MANIFEST_DIR}"
  cat > "${MANIFEST_DIR}/namespaces.yaml" <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: databases
---
apiVersion: v1
kind: Namespace
metadata:
  name: apps
---
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg-system
EOF
  cat > "${MANIFEST_DIR}/cluster.yaml" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: databases
spec:
  instances: ${PG_INSTANCES[$K8S_CLUSTER]}
  imageName: ${PG_IMAGE}
  storage:
    size: ${PG_STORAGE_SIZE[$K8S_CLUSTER]}
    storageClass: ${STORAGE_CLASS[$K8S_CLUSTER]}
    resizeInUseVolumes: true
  bootstrap:
    initdb:
      database: app
      owner: app
  enableSuperuserAccess: true
  enablePDB: true
  resources:
    requests:
      cpu: "${PG_CPU_REQUEST[$K8S_CLUSTER]}"
      memory: "${PG_MEMORY_REQUEST[$K8S_CLUSTER]}"
    limits:
      cpu: "${PG_CPU_LIMIT[$K8S_CLUSTER]}"
      memory: "${PG_MEMORY_LIMIT[$K8S_CLUSTER]}"
EOF
  cat > "${MANIFEST_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespaces.yaml
  - cluster.yaml
EOF
  log "manifests written: $(ls -1 "${MANIFEST_DIR}" | tr '\n' ' ')"
}

apply_operator(){
  require_bin kubectl
  [[ -f "${OPERATOR_MANIFEST}" ]] || fatal "operator manifest missing: ${OPERATOR_MANIFEST}"
  log "preparing operator manifest with CNPG_IMAGE=${CNPG_IMAGE}"
  tmp="$(mktemp)" || fatal "mktemp failed"
  trap '[[ -n "${tmp:-}" ]] && rm -f "${tmp}"' RETURN
  sed -E "s|ghcr.io/cloudnative-pg/cloudnative-pg:[^[:space:]\"'']*|${CNPG_IMAGE}|g" "${OPERATOR_MANIFEST}" > "${tmp}"
  log "applying CNPG operator (server-side preferred)"
  if kubectl apply --server-side --force-conflicts -f "${tmp}" >/dev/null 2>&1; then
    log "operator applied (server-side)"
    return 0
  fi
  log "server-side apply failed; applying client-side"
  kubectl apply -f "${tmp}" >/dev/null 2>&1 || fatal "operator apply failed"
  log "operator applied (client-side)"
}

dump_diagnostics(){
  out="${LOG_DIR}/diagnostics-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${out}"
  {
    printf '=== kubectl client ===\n'
    kubectl version --client --short || true
    printf '\n=== namespaces ===\n'
    kubectl get ns || true
    printf '\n=== cnpg-system: deploys ===\n'
    kubectl -n cnpg-system get deploy -o wide || true
    printf '\n=== cnpg-controller-manager logs (tail 200) ===\n'
    kubectl -n cnpg-system logs deployment/cnpg-controller-manager --tail=200 || true
    printf '\n=== cluster CR YAML ===\n'
    kubectl -n databases get cluster "${CLUSTER_NAME}" -o yaml || true
    printf '\n=== cluster pods (wide) ===\n'
    kubectl -n databases get pods -o wide || true
    printf '\n=== cluster pods logs (tail 15 each) ===\n'
    for p in $(kubectl -n databases get pods -l cnpg.io/cluster="${CLUSTER_NAME}" -o name 2>/dev/null || true); do
      printf "\n=== logs for %s ===\n" "${p##*/}"
      kubectl -n databases logs "${p##*/}" --tail=15 || true
    done
    printf '\n=== secrets and keys ===\n'
    for s in $(kubectl -n databases get secret -o name 2>/dev/null || true); do
      printf '\nsecret: %s\n' "${s##*/}"
      kubectl -n databases get "${s##*/}" -o jsonpath='{.data}' || true
      printf '\n'
    done
    printf '\n=== pvcs ===\n'
    kubectl -n databases get pvc -o wide || true
    printf '\n=== services ===\n'
    kubectl -n databases get svc -o wide || true
    printf '\n=== events (databases) ===\n'
    kubectl -n databases get events --sort-by=.lastTimestamp || true
  } > "${out}/diagnostics.txt" 2>&1
  log "diagnostics written to ${out}/diagnostics.txt"
}

find_superuser_secret(){
  if kubectl -n databases get secret "${CLUSTER_NAME}-superuser" >/dev/null 2>&1; then
    printf '%s' "${CLUSTER_NAME}-superuser"
    return 0
  fi
  for s in $(kubectl -n databases get secret -o name 2>/dev/null || true); do
    if kubectl -n databases get "${s##*/}" -o jsonpath='{.data.password}' >/dev/null 2>&1; then
      printf '%s' "${s##*/}"
      return 0
    fi
  done
  return 1
}

wait_for_superuser_secret(){
  timeout="${SECRET_WAIT_TIMEOUT}"
  waited=0
  interval=5
  log "polling for superuser secret (timeout ${timeout}s)"
  while [[ $waited -lt $timeout ]]; do
    if sec="$(find_superuser_secret)"; then
      printf '%s' "${sec}"
      return 0
    fi
    sleep "${interval}"
    waited=$((waited + interval))
  done
  return 1
}

wait_for_sql_ready(){
  host="$1"
  port="$2"
  pass="$3"
  retries="${SQL_READY_RETRIES}"
  sleep_s="${SQL_READY_SLEEP}"
  i=0
  log "probing SQL readiness (retries=${retries}, sleep=${sleep_s}s)"
  while [[ $i -lt $retries ]]; do
    pod="psql-probe-$(rand)"
    out="$(kubectl -n databases run --rm -i --restart=Never --image="${PSQL_IMAGE}" "${pod}" --env=PGPASSWORD="${pass}" -- sh -c "psql -h ${host} -p ${port} -U postgres -d postgres -t -A -c 'SELECT 1;'" 2>&1 || true)"
    if [[ "$(printf '%s' "${out}" | tr -d '[:space:]')" == "1" ]]; then
      log "SQL ready confirmed"
      return 0
    fi
    log "psql probe attempt $((i+1)) failed; output: ${out:-<no-output>}; retrying"
    sleep "${sleep_s}"
    i=$((i+1))
  done
  return 1
}

create_db_if_missing(){
  host="$1"
  port="$2"
  pass="$3"
  db="$4"
  log "ensuring database exists: ${db}"
  pod="psql-check-$(rand)"
  check="$(kubectl -n databases run --rm -i --restart=Never --image="${PSQL_IMAGE}" "${pod}" --env=PGPASSWORD="${pass}" -- sh -c "psql -h ${host} -p ${port} -U postgres -d postgres -t -A -c \"SELECT 1 FROM pg_database WHERE datname='${db}';\"" 2>&1 || true)"
  if [[ "$(printf '%s' "${check}" | tr -d '[:space:]')" == "1" ]]; then
    log "database ${db} already exists"
    return 0
  fi
  log "creating database ${db}"
  podc="psql-create-$(rand)"
  create_out="$(kubectl -n databases run --rm -i --restart=Never --image="${PSQL_IMAGE}" "${podc}" --env=PGPASSWORD="${pass}" -- sh -c "psql -h ${host} -p ${port} -U postgres -d postgres -c \"CREATE DATABASE \\\"${db}\\\";\"" 2>&1 || true)"
  log "create output: $(printf '%s' "${create_out}" | tr '\n' ' ')"
  if printf '%s' "${create_out}" | grep -qEi 'CREATE DATABASE|already exists'; then
    log "database ${db} created or already exists"
    return 0
  fi
  log "database ${db} creation failed"
  dump_diagnostics
  fatal "failed to create database ${db}"
}

rollout(){
  require_bin kubectl
  render_manifests
  apply_operator
  if ! kubectl get namespace cnpg-system >/dev/null 2>&1; then
    kubectl create namespace cnpg-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  fi
  log "waiting for operator deployment"
  kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout="${OPERATOR_TIMEOUT[$K8S_CLUSTER]}s"
  log "applying cluster manifests"
  kubectl apply -k "${MANIFEST_DIR}" >/dev/null 2>&1 || kubectl apply -k "${MANIFEST_DIR}" -v=6 || fatal "kustomize apply failed"
  log "waiting for Cluster CR Ready"
  kubectl -n databases wait --for=condition=Ready "cluster/${CLUSTER_NAME}" --timeout="${CLUSTER_WAIT_TIMEOUT[$K8S_CLUSTER]}s" || { dump_diagnostics; fatal "cluster ${CLUSTER_NAME} not Ready"; }
  svc="$(kubectl -n databases get svc -l cnpg.io/cluster="${CLUSTER_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -z "${svc}" ]] && svc="${CLUSTER_NAME}"
  host="${svc}.databases.svc.cluster.local"
  port=5432
  log "service resolved: ${svc} -> ${host}:${port}"
  if ! secret_name="$(wait_for_superuser_secret)"; then
    log "superuser secret not found within timeout"
    dump_diagnostics
    fatal "no superuser secret for cluster ${CLUSTER_NAME}"
  fi
  log "using superuser secret: ${secret_name}"
  super_b64="$(kubectl -n databases get secret "${secret_name}" -o jsonpath='{.data.password}' 2>/dev/null || true)"
  if [[ -z "${super_b64}" ]]; then
    dump_diagnostics
    fatal "secret ${secret_name} missing 'password' key"
  fi
  SUPERPASS="$(printf '%s' "${super_b64}" | base64 -d)"
  log "probing SQL connectivity before DB initialization"
  if ! wait_for_sql_ready "${host}" "${port}" "${SUPERPASS}"; then
    dump_diagnostics
    fatal "psql probe failed; cluster not accepting connections"
  fi
  create_db_if_missing "${host}" "${port}" "${SUPERPASS}" flyte_admin
  create_db_if_missing "${host}" "${port}" "${SUPERPASS}" flyte_propeller
  create_db_if_missing "${host}" "${port}" "${SUPERPASS}" mlflow
  create_db_if_missing "${host}" "${port}" "${SUPERPASS}" rising_wave
  cat <<EOF

[SUCCESS] Rollout complete for K8S_CLUSTER=${K8S_CLUSTER}

CONNECTION DETAILS
  HOST=${host}
  PORT=${port}
  SUPERUSER_SECRET=${secret_name}

SUPERUSER connection string:
  postgresql://postgres:<PASSWORD>@${host}:${port}/postgres

TO RETRIEVE PASSWORD:
  kubectl -n databases get secret ${secret_name} -o jsonpath='{.data.password}' | base64 -d

LOGS:
  primary log: ${LOG_FILE}
  diagnostics dir: ${LOG_DIR}/diagnostics-*
EOF
}

case "${1:-}" in
  --rollout) log "starting rollout for K8S_CLUSTER=${K8S_CLUSTER}"; rollout ;;
  --render-only) render_manifests; log "manifests written to ${MANIFEST_DIR}" ;;
  --diagnose) dump_diagnostics ;;
  --help|-h) printf 'Usage: %s [--rollout|--render-only|--diagnose]\n' "$0" ;;
  *) printf 'Unknown option: %s\n' "${1:-}" >&2; exit 1 ;;
esac