#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="postgres-cluster-core-tests"
LOG_DIR="${LOG_DIR:-/tmp/${TEST_NAME}-logs}"
mkdir -p "${LOG_DIR}"
LOG_FILE="$(mktemp "${LOG_DIR}/%Y%m%d_%H%M%S.XXXXXX.log")"
exec > >(tee -a "${LOG_FILE}") 2>&1

KUBE_NS="${KUBE_NS:-databases}"
CNPG_NS="${CNPG_NS:-cnpg-system}"
CLUSTER_NAME="${CLUSTER_NAME:-app-postgres}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16}"
REQUIRED_DATABASES=(flyte_admin flyte_propeller mlflow rising_wave)
KUBECTL_TIMEOUT="${KUBECTL_TIMEOUT:-120s}"
WAIT_CLUSTER_TIMEOUT="${WAIT_CLUSTER_TIMEOUT:-300s}"
SECRET_WAIT_TIMEOUT="${SECRET_WAIT_TIMEOUT:-180}"
SQL_READY_RETRIES="${SQL_READY_RETRIES:-24}"
SQL_READY_SLEEP="${SQL_READY_SLEEP:-5}"

log(){ printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fatal(){ printf '[ERROR] %s\n' "$*" >&2; echo "logfile: ${LOG_FILE}"; exit 1; }
require_bin(){ command -v "$1" >/dev/null 2>&1 || fatal "$1 not found"; }
rand(){ printf '%s' "$(date +%s)-$RANDOM"; }

gather_diagnostics(){
  out="${LOG_DIR}/failure-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${out}"
  {
    printf '=== kubectl client ===\n'
    kubectl version --client --short || true
    printf '\n=== namespaces ===\n'
    kubectl get ns || true
    printf '\n=== cnpg-system: deploys ===\n'
    kubectl -n "${CNPG_NS}" get deploy -o wide || true
    printf '\n=== cnpg-controller-manager logs (tail 200) ===\n'
    kubectl -n "${CNPG_NS}" logs deployment/cnpg-controller-manager --tail=200 || true
    printf '\n=== cluster CR YAML ===\n'
    kubectl -n "${KUBE_NS}" get cluster "${CLUSTER_NAME}" -o yaml || true
    printf '\n=== pods ===\n'
    kubectl -n "${KUBE_NS}" get pods -o wide || true
    printf '\n=== pods logs (tail 15 each) ===\n'
    for p in $(kubectl -n "${KUBE_NS}" get pods -l cnpg.io/cluster="${CLUSTER_NAME}" -o name 2>/dev/null || true); do
      printf "\n=== logs for %s ===\n" "${p##*/}"
      kubectl -n "${KUBE_NS}" logs "${p##*/}" --tail=15 || true
    done
    printf '\n=== secrets and keys ===\n'
    for s in $(kubectl -n "${KUBE_NS}" get secret -o name 2>/dev/null || true); do
      printf '\nsecret: %s\n' "${s##*/}"
      kubectl -n "${KUBE_NS}" get "${s##*/}" -o jsonpath='{.data}' || true
      printf '\n'
    done
    printf '\n=== pvc ===\n'
    kubectl -n "${KUBE_NS}" get pvc -o wide || true
    printf '\n=== events ===\n'
    kubectl -n "${KUBE_NS}" get events --sort-by=.lastTimestamp || true
  } > "${out}/diagnostics.txt" 2>&1
  log "diagnostics written to ${out}/diagnostics.txt"
  log "full run logfile: ${LOG_FILE}"
}

on_error(){
  ec=$?
  log "TEST FAILED exit=${ec}"
  gather_diagnostics
  exit ${ec}
}
trap on_error ERR

find_superuser_secret(){
  if kubectl -n "${KUBE_NS}" get secret "${CLUSTER_NAME}-superuser" >/dev/null 2>&1; then
    printf '%s' "${CLUSTER_NAME}-superuser"
    return 0
  fi
  for s in $(kubectl -n "${KUBE_NS}" get secret -o name 2>/dev/null || true); do
    if kubectl -n "${KUBE_NS}" get "${s##*/}" -o jsonpath='{.data.password}' >/dev/null 2>&1; then
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
  log "waiting for secret with password (timeout ${timeout}s)"
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

psql_probe(){
  host="$1"
  port="$2"
  pass="$3"
  pod="psql-probe-$(rand)"
  out="$(kubectl -n "${KUBE_NS}" run --rm -i --restart=Never --image="${PSQL_IMAGE}" "${pod}" --env=PGPASSWORD="${pass}" -- sh -c "psql -h ${host} -p ${port} -U postgres -d postgres -t -A -c 'SELECT 1;'" 2>&1 || true)"
  printf '%s' "${out}"
}

main(){
  require_bin kubectl
  log "starting ${TEST_NAME}"
  log "logfile: ${LOG_FILE}"
  kubectl get ns "${KUBE_NS}" >/dev/null 2>&1 || { log "namespace ${KUBE_NS} missing"; exit 3; }
  kubectl get ns "${CNPG_NS}" >/dev/null 2>&1 || { log "namespace ${CNPG_NS} missing"; exit 3; }
  log "checking operator rollout"
  kubectl -n "${CNPG_NS}" rollout status deployment/cnpg-controller-manager --timeout="${KUBECTL_TIMEOUT}" >/dev/null 2>&1
  log "waiting for Cluster CR Ready"
  kubectl -n "${KUBE_NS}" wait --for=condition=Ready "cluster/${CLUSTER_NAME}" --timeout="${WAIT_CLUSTER_TIMEOUT}"
  svc="$(kubectl -n "${KUBE_NS}" get svc -l cnpg.io/cluster="${CLUSTER_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -z "${svc}" ]] && svc="${CLUSTER_NAME}"
  host="${svc}.${KUBE_NS}.svc.cluster.local"
  port=5432
  log "service resolved: ${svc} -> ${host}:${port}"
  if ! secret="$(wait_for_superuser_secret)"; then
    log "superuser secret not found"
    exit 4
  fi
  log "using superuser secret: ${secret}"
  super_b64="$(kubectl -n "${KUBE_NS}" get secret "${secret}" -o jsonpath='{.data.password}' 2>/dev/null || true)"
  if [[ -z "${super_b64}" ]]; then
    log "secret ${secret} missing 'password' key"
    exit 5
  fi
  SUPERPASS="$(printf '%s' "${super_b64}" | base64 -d)"
  log "running connectivity probe"
  probe_out="$(psql_probe "${host}" "${port}" "${SUPERPASS}")"
  log "connectivity probe output: ${probe_out}"
  if [[ "$(printf '%s' "${probe_out}" | tr -d '[:space:]')" != "1" ]]; then
    log "connectivity probe failed"
    exit 6
  fi
  log "connectivity OK"
  log "verifying required databases: ${REQUIRED_DATABASES[*]}"
  query="SELECT datname FROM pg_database WHERE datname IN ('$(IFS="','"; echo "${REQUIRED_DATABASES[*]}")') ORDER BY datname;"
  dbs_out="$(kubectl -n "${KUBE_NS}" run --rm -i --restart=Never --image="${PSQL_IMAGE}" psql-list --env=PGPASSWORD="${SUPERPASS}" -- sh -c "psql -h ${host} -p ${port} -U postgres -d postgres -t -A -c \"${query}\"" 2>&1 || true)"
  dbs_clean="$(printf '%s' "${dbs_out}" | sed '/^\s*$/d' || true)"
  log "databases discovered: ${dbs_clean:-<none>}"
  missing=()
  for d in "${REQUIRED_DATABASES[@]}"; do
    if ! grep -q "^${d}$" <<< "${dbs_clean}"; then
      missing+=("${d}")
    fi
  done
  if [[ ${#missing[@]} -ne 0 ]]; then
    log "MISSING DATABASES: ${missing[*]}"
    exit 7
  fi
  log "all required databases present"
  log "performing write smoke test on ${REQUIRED_DATABASES[0]}"
  write_out="$(kubectl -n "${KUBE_NS}" run --rm -i --restart=Never --image="${PSQL_IMAGE}" psql-write --env=PGPASSWORD="${SUPERPASS}" -- sh -c "psql -h ${host} -p ${port} -U postgres -d ${REQUIRED_DATABASES[0]} -c \"CREATE TABLE IF NOT EXISTS test_autogen(id serial PRIMARY KEY); DROP TABLE test_autogen;\"" 2>&1 || true)"
  log "write test output: ${write_out}"
  if printf '%s' "${write_out}" | grep -qi 'ERROR'; then
    log "write test returned ERROR"
    exit 8
  fi
  cat <<EOF

TEST SUMMARY
  test: ${TEST_NAME}
  cluster: ${CLUSTER_NAME}
  namespace: ${KUBE_NS}
  service: ${svc}
  host: ${host}
  port: ${port}
  superuser_secret: ${secret}
  required_databases: ${REQUIRED_DATABASES[*]}
  logfile: ${LOG_FILE}

HOW TO CONNECT (exact copy-paste)
  export PGPASSWORD="$(kubectl -n ${KUBE_NS} get secret ${secret} -o jsonpath='{.data.password}' | base64 -d)"
  psql -h ${host} -p ${port} -U postgres -d postgres

SUCCESS: all checks passed

EOF
  log "test completed successfully"
  exit 0
}

main "$@"