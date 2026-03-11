#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests/postgres"
ARCHIVE_DIR="${ARCHIVE_DIR:-src/scripts/archive}"
K8S_CLUSTER="${K8S_CLUSTER:-kind}"
CLUSTER_NAME="${CLUSTER_NAME:-app-postgres}"

declare -A STORAGE_CLASS=( [kind]="local-path" [eks]="gp3" )
declare -A PG_INSTANCES=( [kind]="1" [eks]="3" )
declare -A PG_STORAGE_SIZE=( [kind]="5Gi" [eks]="20Gi" )
declare -A PG_CPU_REQUEST=( [kind]="250m" [eks]="500m" )
declare -A PG_MEMORY_REQUEST=( [kind]="512Mi" [eks]="1Gi" )
declare -A PG_CPU_LIMIT=( [kind]="500m" [eks]="1" )
declare -A PG_MEMORY_LIMIT=( [kind]="1Gi" [eks]="2Gi" )
declare -A OPERATOR_TIMEOUT=( [kind]="120" [eks]="300" )
declare -A CLUSTER_WAIT_TIMEOUT=( [kind]="300" [eks]="900" )
declare -A PG_MAX_CONNECTIONS=( [kind]="100" [eks]="200" )

PG_DBS="${PG_DBS:-flyteadmin,flytepropeller,mlflow,risingwave}"
PG_POOLER_SERVICE="${PG_POOLER_SERVICE:-app-postgres-pooler}"
PG_POOLER_PORT="${PG_POOLER_PORT:-5432}"
PG_IMAGE="${PG_IMAGE:-ghcr.io/cloudnative-pg/postgresql:18.3-minimal-trixie}"
CNPG_IMAGE="${CNPG_IMAGE:-ghcr.io/cloudnative-pg/cloudnative-pg:1.28.1}"
PGBOUNCER_IMAGE="${PGBOUNCER_IMAGE:-ghcr.io/cloudnative-pg/pgbouncer:1.25.1}"

FLYTE_ADMIN_DB_PASSWORD="${FLYTE_ADMIN_DB_PASSWORD:-}"
FLYTE_PROPELLER_DB_PASSWORD="${FLYTE_PROPELLER_DB_PASSWORD:-}"
MLFLOW_DB_PASSWORD="${MLFLOW_DB_PASSWORD:-}"
RISING_WAVE_DB_PASSWORD="${RISING_WAVE_DB_PASSWORD:-}"

WAIT_FOR_ROLE_TIMEOUT="${WAIT_FOR_ROLE_TIMEOUT:-180}"
WAIT_FOR_ROLE_INTERVAL="${WAIT_FOR_ROLE_INTERVAL:-3}"
PG_USER="${PG_USER:-postgres}"
PG_PASSWORD="${PG_PASSWORD:-}"

log(){ printf '[%s] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$K8S_CLUSTER" "$*" >&2; }
fatal(){ printf '[ERROR] [%s] %s\n' "$K8S_CLUSTER" "$*" >&2; exit 1; }
require_bin(){ command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }
trim(){ printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
env_password_for_db(){
  local db="$1"
  case "$db" in
    flyteadmin) printf '%s' "${FLYTE_ADMIN_DB_PASSWORD:-}" ;;
    flytepropeller) printf '%s' "${FLYTE_PROPELLER_DB_PASSWORD:-}" ;;
    mlflow) printf '%s' "${MLFLOW_DB_PASSWORD:-}" ;;
    risingwave) printf '%s' "${RISING_WAVE_DB_PASSWORD:-}" ;;
    *) printf '%s' "" ;;
  esac
}

check_cluster(){
  require_bin kubectl
  if kubectl version --request-timeout=5s >/dev/null 2>&1; then
    log "kubernetes API reachable"
  else
    fatal "kubernetes api not reachable; verify kubeconfig and cluster"
  fi
}

ensure_namespace(){
  local ns="$1"
  if kubectl get namespace "${ns}" >/dev/null 2>&1; then
    log "namespace ${ns} exists"
  else
    kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    log "namespace ${ns} created"
  fi
}

render_cluster_manifest(){
  mkdir -p "${MANIFEST_DIR}"
  local cluster_file="${MANIFEST_DIR}/cluster.yaml"
  cat > "${cluster_file}" <<EOF
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
      database: postgres
      owner: postgres
  enableSuperuserAccess: true
  enablePDB: true
  resources:
    requests:
      cpu: "${PG_CPU_REQUEST[$K8S_CLUSTER]}"
      memory: "${PG_MEMORY_REQUEST[$K8S_CLUSTER]}"
    limits:
      cpu: "${PG_CPU_LIMIT[$K8S_CLUSTER]}"
      memory: "${PG_MEMORY_LIMIT[$K8S_CLUSTER]}"
  postgresql:
    parameters:
      max_connections: "${PG_MAX_CONNECTIONS[$K8S_CLUSTER]}"
    pg_hba: []
  managed:
    roles:
EOF

  IFS=',' read -ra DBS <<< "$PG_DBS"
  for raw in "${DBS[@]}"; do
    db="$(trim "${raw}")"
    [ -z "${db}" ] && continue
    printf '    - name: %s_user\n' "${db}" >> "${cluster_file}"
    printf '      ensure: present\n' >> "${cluster_file}"
    printf '      login: true\n' >> "${cluster_file}"
    printf '      superuser: false\n' >> "${cluster_file}"
    printf '      passwordSecret:\n' >> "${cluster_file}"
    printf '        name: cnpg-role-%s\n' "${db}" >> "${cluster_file}"
  done

  log "cluster manifest rendered to ${cluster_file}"
}

create_superuser_secret(){
  if [[ -z "${PG_PASSWORD:-}" ]]; then
    fatal "PG_PASSWORD must be set (PG_USER=${PG_USER}) to create required superuser secret"
  fi
  local secret_name="${CLUSTER_NAME}-superuser"
  ensure_namespace "databases"
  if kubectl -n databases get secret "${secret_name}" >/dev/null 2>&1; then
    log "superuser secret ${secret_name} exists; preserved"
    return 0
  fi
  kubectl -n databases create secret generic "${secret_name}" --type="kubernetes.io/basic-auth" --from-literal=username="${PG_USER}" --from-literal=password="${PG_PASSWORD}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "created superuser secret ${secret_name}"
}

create_role_secret_for_db(){
  local db="$1"
  local secret="cnpg-role-${db}"
  local user="${db}_user"
  local provided; provided="$(env_password_for_db "${db}")" || true
  if kubectl -n databases get secret "${secret}" >/dev/null 2>&1; then
    log "secret ${secret} exists; preserved"
    return 0
  fi
  if [[ -n "${provided:-}" ]]; then
    kubectl -n databases create secret generic "${secret}" --type="kubernetes.io/basic-auth" --from-literal=username="${user}" --from-literal=password="${provided}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    log "created secret ${secret} from env"
    return 0
  fi
  local pw; pw="$(openssl rand -base64 18)" || fatal "password generation failed"
  kubectl -n databases create secret generic "${secret}" --type="kubernetes.io/basic-auth" --from-literal=username="${user}" --from-literal=password="${pw}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "created secret ${secret} with generated password"
}

create_all_role_secrets(){
  ensure_namespace "databases"
  IFS=',' read -ra DBS <<< "$PG_DBS"
  for raw in "${DBS[@]}"; do
    db="$(trim "${raw}")"
    [ -z "${db}" ] && continue
    create_role_secret_for_db "${db}"
  done
}

render_database_crds(){
  local db_dir="${MANIFEST_DIR}/databases"
  mkdir -p "${db_dir}"
  IFS=',' read -ra DBS <<< "$PG_DBS"
  for raw in "${DBS[@]}"; do
    db="$(trim "${raw}")"
    [ -z "${db}" ] && continue
    cat > "${db_dir}/${db}.yaml" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: ${db}
  namespace: databases
spec:
  cluster:
    name: ${CLUSTER_NAME}
  name: ${db}
  owner: ${db}_user
  ensure: present
EOF
    log "wrote Database CR for ${db} to ${db_dir}/${db}.yaml"
  done
}

render_pgbouncer_manifests(){
  local cfg_dir="${MANIFEST_DIR}/pgbouncer"
  mkdir -p "${cfg_dir}"
  local cm="${cfg_dir}/pgbouncer-config.yaml"
  local deploy="${cfg_dir}/pgbouncer-deploy.yaml"
  local svc="${cfg_dir}/pgbouncer-svc.yaml"

  IFS=',' read -ra DBS <<< "$PG_DBS"
  local tmpfile; tmpfile="$(mktemp)" || fatal "mktemp failed"
  : > "${tmpfile}"
  for raw in "${DBS[@]}"; do
    db="$(trim "${raw}")"
    [ -z "${db}" ] && continue
    local secret="cnpg-role-${db}"
    local user; user="$(kubectl -n databases get secret "${secret}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)" || fatal "failed reading ${secret} username"
    local pw; pw="$(kubectl -n databases get secret "${secret}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)" || fatal "failed reading ${secret} password"
    local md5hex; md5hex="$(printf '%s%s' "${pw}" "${user}" | md5sum | awk '{print $1}')" || fatal "md5 failed"
    printf '%s="%s"\n' "${user}" "md5${md5hex}" >> "${tmpfile}"
  done

  {
    echo "apiVersion: v1"
    echo "kind: ConfigMap"
    echo "metadata:"
    echo "  name: app-postgres-pgbouncer-config"
    echo "  namespace: databases"
    echo "data:"
    echo "  pgbouncer.ini: |"
    echo "    [databases]"
    for raw in "${DBS[@]}"; do
      db="$(trim "${raw}")"
      [ -z "${db}" ] && continue
      echo "    ${db} = host=${CLUSTER_NAME}-rw.databases.svc.cluster.local port=5432 dbname=${db}"
    done
    echo "    [pgbouncer]"
    echo "    listen_addr = 0.0.0.0"
    echo "    listen_port = 5432"
    echo "    auth_type = md5"
    echo "    auth_file = /etc/pgbouncer/userlist.txt"
    echo "    pool_mode = transaction"
    echo "    server_reset_query = DISCARD ALL"
    echo "  userlist.txt: |"
    while IFS= read -r line; do
      name="$(printf '%s' "${line}" | cut -d= -f1)"
      hash="$(printf '%s' "${line}" | cut -d= -f2- | tr -d '"')"
      echo "    \"${name}\" \"${hash}\""
    done < "${tmpfile}"
  } > "${cm}"

  cat > "${deploy}" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PG_POOLER_SERVICE}
  namespace: databases
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PG_POOLER_SERVICE}
  template:
    metadata:
      labels:
        app: ${PG_POOLER_SERVICE}
    spec:
      containers:
        - name: pgbouncer
          image: ${PGBOUNCER_IMAGE}
          args: ["/usr/bin/pgbouncer","/etc/pgbouncer/pgbouncer.ini"]
          volumeMounts:
            - name: pgbouncer-config
              mountPath: /etc/pgbouncer
      volumes:
        - name: pgbouncer-config
          configMap:
            name: app-postgres-pgbouncer-config
EOF

  cat > "${svc}" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${PG_POOLER_SERVICE}
  namespace: databases
spec:
  selector:
    app: ${PG_POOLER_SERVICE}
  ports:
    - port: ${PG_POOLER_PORT}
      targetPort: 5432
      protocol: TCP
EOF

  rm -f "${tmpfile}"
  log "pgbouncer manifests rendered to ${cfg_dir}"
}

fix_kustomization_if_legacy(){
  local k="${MANIFEST_DIR}/kustomization.yaml"
  if [[ -f "${k}" ]]; then
    if grep -q "apiVersion: kustomize.config.k8s.io/v1beta1" "${k}" 2>/dev/null; then
      log "legacy kustomization apiVersion detected; updating to kustomize.config.k8s.io/v1"
      sed -E -i.bak 's|apiVersion:[[:space:]]*kustomize.config.k8s.io/v1beta1|apiVersion: kustomize.config.k8s.io/v1|' "${k}" || true
      rm -f "${k}.bak" || true
      log "kustomization apiVersion updated"
    fi
  fi
}

validate_manifests(){
  local dir="$1"
  local errors=0
  while IFS= read -r -d '' f; do
    [ "$(basename "$f")" = "kustomization.yaml" ] && continue
    if ! kubectl apply --server-side --dry-run=client -f "$f" >/dev/null 2>&1; then
      local msg
      msg="$(kubectl apply --server-side --dry-run=client -f "$f" 2>&1 || true)"
      fatal "manifest validation failed for $f: ${msg}"
      errors=$((errors+1))
    fi
  done < <(find "$dir" -type f -name '*.y*ml' -print0)
  if [[ "${errors}" -eq 0 ]]; then
    log "manifests validation passed under ${dir}"
  fi
}

apply_operator(){
  require_bin kubectl
  local operator_manifest="${ARCHIVE_DIR}/cnpg-1.28.1.yaml"
  if [[ -f "${operator_manifest}" ]]; then
    log "using local operator manifest ${operator_manifest}"
    local tmp; tmp="$(mktemp)" || fatal "mktemp failed"
    trap '[[ -n "${tmp:-}" ]] && rm -f "$tmp"' RETURN
    local escaped; escaped="$(printf '%s' "$CNPG_IMAGE" | sed -e 's/[\/&]/\\&/g')"
    sed -E "s|ghcr.io/cloudnative-pg/cloudnative-pg:[^[:space:]\"']*|${escaped}|g" "${operator_manifest}" > "${tmp}"
    if kubectl apply --server-side --force-conflicts -f "${tmp}" >/dev/null 2>&1; then
      log "operator applied (server-side) from local manifest"
      return 0
    fi
    if kubectl apply -f "${tmp}" >/dev/null 2>&1; then
      log "operator applied (client-side) from local manifest"
      return 0
    fi
    fatal "operator apply failed (local)"
  fi
  log "fetching operator manifest from upstream"
  local url="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.1.yaml"
  if kubectl apply --server-side --force-conflicts -f "${url}" >/dev/null 2>&1; then
    log "operator applied (server-side) from ${url}"
    return 0
  fi
  if kubectl apply -f "${url}" >/dev/null 2>&1; then
    log "operator applied (client-side) from ${url}"
    return 0
  fi
  fatal "operator apply failed (remote)"
}

apply_if_changed(){
  local dir="$1"
  if kubectl diff -f "${dir}" --recursive >/dev/null 2>&1; then
    log "no changes detected in ${dir}; skipping apply"
    return 0
  fi
  log "changes detected; applying ${dir} recursively with server-side apply"
  if kubectl apply --server-side --force-conflicts -f "${dir}" --recursive >/dev/null 2>&1; then
    log "applied (server-side) ${dir}"
    return 0
  fi
  kubectl apply -f "${dir}" --recursive
}

wait_for_managed_roles_reconciled(){
  IFS=',' read -ra DBS <<< "$PG_DBS"
  local expected=()
  for raw in "${DBS[@]}"; do
    db="$(trim "${raw}")"
    [ -z "${db}" ] && continue
    expected+=( "${db}_user" )
  done
  local want_count="${#expected[@]}"
  local timeout="${WAIT_FOR_ROLE_TIMEOUT}"
  local interval="${WAIT_FOR_ROLE_INTERVAL}"
  local start; start="$(date +%s)"
  log "waiting up to ${timeout}s for ${want_count} managed roles to be reconciled by operator"
  while true; do
    local reconciled
    reconciled="$(kubectl -n databases get cluster "${CLUSTER_NAME}" -o jsonpath='{.status.managedRolesStatus.byStatus.reconciled[*]}' 2>/dev/null || true)"
    local found=0
    for r in "${expected[@]}"; do
      case " ${reconciled} " in (*" ${r} "*) found=$((found+1));; esac
    done
    if [ "${found}" -eq "${want_count}" ]; then
      log "managed roles reconciled: ${reconciled}"
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "${timeout}" ]; then
      kubectl -n databases get cluster "${CLUSTER_NAME}" -o yaml || true
      kubectl -n databases get pods -o wide || true
      fatal "timeout waiting for managed roles reconciled (found ${found}/${want_count})"
    fi
    sleep "${interval}"
  done
}

wait_for_ready(){
  local ns="$1"
  local kind="$2"
  local name="$3"
  local timeout="${4:-120}"
  log "waiting up to ${timeout}s for ${kind}/${name} in ${ns} to be Ready"
  if ! kubectl -n "${ns}" rollout status "${kind}/${name}" --timeout="${timeout}s" >/dev/null 2>&1; then
    kubectl -n "${ns}" get pods -o wide || true
    fatal "${kind} ${name} not Ready"
  fi
  log "${kind}/${name} Ready"
}

wait_for_cluster_ready(){
  local timeout="${CLUSTER_WAIT_TIMEOUT[$K8S_CLUSTER]}"
  log "waiting up to ${timeout}s for Cluster CR to become Ready"
  if ! kubectl -n databases wait --for=condition=Ready "cluster/${CLUSTER_NAME}" --timeout="${timeout}s" >/dev/null 2>&1; then
    kubectl -n databases get cluster "${CLUSTER_NAME}" -o yaml || true
    kubectl -n databases get pods -o wide || true
    kubectl -n databases get events --sort-by=.lastTimestamp || true
    fatal "cluster ${CLUSTER_NAME} not Ready"
  fi
  log "Cluster ${CLUSTER_NAME} Ready"
}

wait_for_role_ready_via_pgbouncer(){
  local db="$1"
  local secret="cnpg-role-${db}"
  local pw; pw="$(kubectl -n databases get secret "${secret}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)" || fatal "failed reading ${secret}"
  local user="${db}_user"
  local timeout="${WAIT_FOR_ROLE_TIMEOUT}"
  local interval="${WAIT_FOR_ROLE_INTERVAL}"
  log "waiting up to ${timeout}s for role ${user} to be usable via pgbouncer"
  local start; start="$(date +%s)"
  while true; do
    if kubectl -n databases run --rm -i --restart=Never --image=postgres:16 pg-test-"${db}" --env PGPASSWORD="${pw}" --command -- psql -h ${PG_POOLER_SERVICE}.databases.svc.cluster.local -U "${user}" -d "${db}" -c 'SELECT 1' >/dev/null 2>&1; then
      log "role ${user} usable via pgbouncer"
      break
    fi
    if [ $(( $(date +%s) - start )) -ge "${timeout}" ]; then
      fatal "timeout waiting for role ${user} on db ${db} via pgbouncer"
    fi
    sleep "${interval}"
  done
}

apply_pgbouncer(){
  local cfg_dir="${MANIFEST_DIR}/pgbouncer"
  kubectl -n databases apply -f "${cfg_dir}/pgbouncer-config.yaml"
  kubectl -n databases apply -f "${cfg_dir}/pgbouncer-deploy.yaml"
  kubectl -n databases apply -f "${cfg_dir}/pgbouncer-svc.yaml"
  log "pgbouncer applied"
}

rollout(){
  require_bin kubectl
  require_bin openssl
  require_bin md5sum
  check_cluster
  ensure_namespace "cnpg-system"
  ensure_namespace "databases"
  render_cluster_manifest
  create_all_role_secrets
  create_superuser_secret
  fix_kustomization_if_legacy
  apply_operator
  log "waiting for CNPG controller manager"
  if ! kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout="${OPERATOR_TIMEOUT[$K8S_CLUSTER]}s" >/dev/null 2>&1; then
    kubectl -n cnpg-system get pods -o wide || true
    fatal "cnpg-controller-manager not ready"
  fi
  validate_manifests "${MANIFEST_DIR}"
  apply_if_changed "${MANIFEST_DIR}"
  wait_for_cluster_ready
  wait_for_managed_roles_reconciled
  render_database_crds
  validate_manifests "${MANIFEST_DIR}/databases"
  apply_if_changed "${MANIFEST_DIR}/databases"
  render_pgbouncer_manifests
  validate_manifests "${MANIFEST_DIR}/pgbouncer"
  apply_pgbouncer
  wait_for_ready "databases" "deployment" "${PG_POOLER_SERVICE}" 120
  IFS=',' read -ra DBS <<< "$PG_DBS"
  for raw in "${DBS[@]}"; do
    db="$(trim "${raw}")"
    [ -z "${db}" ] && continue
    wait_for_role_ready_via_pgbouncer "${db}"
  done
  log "rollout successful"
  echo
  echo "Connection summary:"
  local host="${PG_POOLER_SERVICE}.databases.svc.cluster.local"
  local port="${PG_POOLER_PORT}"
  for raw in "${DBS[@]}"; do
    db="$(trim "${raw}")"
    [ -z "${db}" ] && continue
    local secret="cnpg-role-${db}"
    local user; user="$(kubectl -n databases get secret "${secret}" -o jsonpath='{.data.username}' | base64 -d)"
    printf '  %s -> postgresql://%s:<PASSWORD>@%s:%s/%s\n' "${db}" "${user}" "${host}" "${port}" "${db}"
  done
  echo
}

delete_resources(){
  require_bin kubectl
  kubectl -n databases delete -f "${MANIFEST_DIR}" --recursive --ignore-not-found=true || true
  if [[ -f "${ARCHIVE_DIR}/cnpg-1.28.1.yaml" ]]; then
    kubectl delete -f "${ARCHIVE_DIR}/cnpg-1.28.1.yaml" --ignore-not-found=true || true
  else
    kubectl delete -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.1.yaml --ignore-not-found=true || true
  fi
  IFS=',' read -ra DBS <<< "$PG_DBS"
  for raw in "${DBS[@]}"; do
    db="$(trim "${raw}")"
    [ -z "${db}" ] && continue
    kubectl -n databases delete secret "cnpg-role-${db}" --ignore-not-found=true || true
    kubectl -n databases delete database "${db}" --ignore-not-found=true || true
  done
  kubectl -n databases delete secret "${PG_POOLER_SERVICE}" --ignore-not-found=true || true
  kubectl -n databases delete configmap app-postgres-pgbouncer-config --ignore-not-found=true || true
  kubectl -n databases delete deployment "${PG_POOLER_SERVICE}" --ignore-not-found=true || true
  kubectl -n databases delete service "${PG_POOLER_SERVICE}" --ignore-not-found=true || true
  kubectl -n databases delete secret "${CLUSTER_NAME}-superuser" --ignore-not-found=true || true
  log "delete initiated"
}

case "${1:-}" in
  --rollout)
    log "starting rollout for K8S_CLUSTER=${K8S_CLUSTER}"
    rollout
    ;;
  --delete)
    log "starting delete for K8S_CLUSTER=${K8S_CLUSTER}"
    delete_resources
    ;;
  --render-only)
    render_cluster_manifest
    render_pgbouncer_manifests
    render_database_crds
    log "manifests written to ${MANIFEST_DIR}"
    echo "[DRY-RUN] To apply, run: $0 --rollout"
    ;;
  --help|-h)
    cat <<'EOF'
Usage: $0 [OPTION]

Options:
  --rollout        Apply CNPG Cluster and a TLS-free PgBouncer (full deploy)
  --delete         Delete cluster, pgbouncer and secrets (idempotent)
  --render-only    Write manifests only
EOF
    ;;
  *)
    echo "Unknown option: ${1:-}" >&2
    exit 1
    ;;
esac