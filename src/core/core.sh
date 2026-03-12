#!/usr/bin/env bash
set -euo pipefail

K8S_CLUSTER="${K8S_CLUSTER:-kind}"
TARGET_NS="${TARGET_NS:-default}"
ROOT_DIR="$(pwd)"
MANIFEST_DIR="${ROOT_DIR}/src/manifests/postgres_cluster"
GENERATED_DIR="${ROOT_DIR}/src/manifests/generated"
CLUSTER_FILE="${MANIFEST_DIR}/postgres_cluster.yaml"
POOLER_FILE="${MANIFEST_DIR}/postgres_pooler.yaml"

CNPG_VERSION="1.27.2"
CNPG_NAMESPACE="cnpg-system"
POSTGRES_IMAGE="ghcr.io/cloudnative-pg/postgresql:16.13"
CLUSTER_NAME="postgres-cluster"
POOLER_NAME="postgres-pooler"

LOCAL_PATH_PROVISIONER_TAG="v0.0.35"

OPERATOR_TIMEOUT=${OPERATOR_TIMEOUT:-300}
POD_TIMEOUT=${POD_TIMEOUT:-900}
SECRET_TIMEOUT=${SECRET_TIMEOUT:-120}

declare -A SC_NAME=( [kind]="local-path" [eks]="gp3" )
declare -A SC_PROVISIONER=( [kind]="rancher.io/local-path" [eks]="ebs.csi.aws.com" )
declare -A SC_BIND_MODE=( [kind]="Immediate" [eks]="WaitForFirstConsumer" )

if [[ "${K8S_CLUSTER}" == "kind" ]]; then
  INSTANCES=2
  CPU_REQUEST="250m"
  CPU_LIMIT="1000m"
  MEM_REQUEST="512Mi"
  MEM_LIMIT="1Gi"
  STORAGE_SIZE="5Gi"
  WAL_SIZE="2Gi"
  POOLER_INSTANCES=1
  POOLER_CPU_REQUEST="50m"
  POOLER_MEM_REQUEST="64Mi"
  POOLER_CPU_LIMIT="200m"
  POOLER_MEM_LIMIT="256Mi"
else
  INSTANCES=3
  CPU_REQUEST="500m"
  CPU_LIMIT="2000m"
  MEM_REQUEST="1Gi"
  MEM_LIMIT="4Gi"
  STORAGE_SIZE="20Gi"
  WAL_SIZE="10Gi"
  POOLER_INSTANCES=2
  POOLER_CPU_REQUEST="100m"
  POOLER_MEM_REQUEST="128Mi"
  POOLER_CPU_LIMIT="500m"
  POOLER_MEM_LIMIT="512Mi"
fi

log(){ printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
fatal(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
require_bin(){ command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }

trap 'rc=$?; echo; echo "[DIAG] exit_code=$rc"; echo "[DIAG] kubectl context: $(kubectl config current-context 2>/dev/null || true)"; echo "[DIAG] pods (all namespaces):"; kubectl get pods -A -o wide || true; echo "[DIAG] pvcs (target ns):"; kubectl -n "${TARGET_NS}" get pvc || true; echo "[DIAG] events (last 200):"; kubectl get events -A --sort-by=.lastTimestamp | tail -n 200 || true; echo "[DIAG] operator logs (cnpg-system):"; kubectl -n cnpg-system logs deployment/cnpg-controller-manager --tail=200 || true; echo "[DIAG] cluster CR (if present):"; kubectl -n "${TARGET_NS}" get cluster "${CLUSTER_NAME}" -o yaml || true; exit $rc' ERR

require_prereqs(){
  require_bin kubectl
  require_bin curl
  kubectl version --client >/dev/null 2>&1 || fatal "kubectl client unavailable"
  kubectl cluster-info >/dev/null 2>&1 || fatal "kubectl cannot reach cluster"
}

check_eks_csi(){
  if [[ "${K8S_CLUSTER}" != "eks" ]]; then
    return 0
  fi
  log "checking for EBS CSI driver"
  if kubectl get csidrivers | grep -q 'ebs.csi.aws.com'; then
    log "EBS CSI driver present"
    return 0
  fi
  fatal "EBS CSI driver not found. Install aws-ebs-csi-driver and ensure node IAM permissions"
}

ensure_storage_class(){
  if [[ ! "${SC_NAME[$K8S_CLUSTER]+isset}" ]]; then
    fatal "unsupported K8S_CLUSTER=${K8S_CLUSTER}"
  fi
  local sc="${SC_NAME[$K8S_CLUSTER]}"
  local provisioner="${SC_PROVISIONER[$K8S_CLUSTER]}"
  local bind="${SC_BIND_MODE[$K8S_CLUSTER]}"
  log "checking StorageClass ${sc}"
  if kubectl get storageclass "${sc}" >/dev/null 2>&1; then
    log "StorageClass ${sc} exists"
    return 0
  fi
  if [[ "${K8S_CLUSTER}" == "kind" ]]; then
    log "installing local-path-provisioner ${LOCAL_PATH_PROVISIONER_TAG}"
    kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_TAG}/deploy/local-path-storage.yaml" >/dev/null 2>&1 || fatal "failed to install local-path-provisioner"
    kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=180s >/dev/null || log "warning: local-path-provisioner rollout may not be fully ready"
  else
    log "creating gp3 StorageClass for EKS"
    kubectl apply -f - >/dev/null <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${sc}
provisioner: ${provisioner}
parameters:
  type: gp3
  encrypted: "true"
  fsType: ext4
reclaimPolicy: Delete
volumeBindingMode: ${bind}
allowVolumeExpansion: true
EOF
  fi
  kubectl get storageclass "${sc}" >/dev/null || fatal "StorageClass ${sc} verification failed"
  log "StorageClass ${sc} ready"
}

install_cnpg_operator(){
  log "installing CloudNativePG operator ${CNPG_VERSION}"
  kubectl get ns "${CNPG_NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${CNPG_NAMESPACE}" >/dev/null
  local branch="${CNPG_VERSION%.*}"
  local url="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${branch}/releases/cnpg-${CNPG_VERSION}.yaml"
  log "applying operator manifest from ${url}"
  if kubectl apply --server-side -f "${url}" >/dev/null 2>&1; then
    log "operator manifest applied (server-side)"
  else
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "${tmp}"' EXIT
    curl -fsSL "${url}" -o "${tmp}" || fatal "failed to download operator manifest"
    kubectl apply -f "${tmp}" >/dev/null || fatal "kubectl apply failed for operator manifest"
    trap - EXIT
  fi
  kubectl -n "${CNPG_NAMESPACE}" rollout status deployment/cnpg-controller-manager --timeout="${OPERATOR_TIMEOUT}s" >/dev/null || fatal "cnpg-controller-manager rollout failed or timed out"
  kubectl get crd clusters.postgresql.cnpg.io >/dev/null || fatal "CRD clusters.postgresql.cnpg.io missing"
  log "operator ready"
}

render_cluster_manifest(){
  log "rendering postgres Cluster manifest with strong defaults"
  mkdir -p "${MANIFEST_DIR}"
  cat > "${CLUSTER_FILE}" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${TARGET_NS}
spec:
  instances: ${INSTANCES}
  imageName: ${POSTGRES_IMAGE}
  bootstrap:
    initdb:
      postInitSQL:
        - CREATE DATABASE flyte_admin;
        - CREATE DATABASE flyte_propeller;
        - CREATE DATABASE mlflow;
        - CREATE DATABASE rising_wave;
  storage:
    storageClass: ${SC_NAME[$K8S_CLUSTER]}
    size: ${STORAGE_SIZE}
  walStorage:
    storageClass: ${SC_NAME[$K8S_CLUSTER]}
    size: ${WAL_SIZE}
  postgresql:
    parameters:
      shared_buffers: "256MB"
      max_connections: "200"
      wal_compression: "on"
      effective_cache_size: "1GB"
  template:
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  cnpg.io/cluster: ${CLUSTER_NAME}
              topologyKey: "kubernetes.io/hostname"
      containers:
      - name: postgres
        resources:
          requests:
            cpu: ${CPU_REQUEST}
            memory: ${MEM_REQUEST}
          limits:
            cpu: ${CPU_LIMIT}
            memory: ${MEM_LIMIT}
EOF
  log "cluster manifest written: ${CLUSTER_FILE}"
}

deploy_cluster(){
  log "applying cluster manifest"
  kubectl apply -f "${CLUSTER_FILE}" >/dev/null
}

wait_for_cluster_ready(){
  log "waiting for cluster readiness (timeout ${POD_TIMEOUT}s)"
  local start now elapsed
  start=$(date +%s)
  while true; do
    now=$(date +%s)
    elapsed=$((now - start))
    if [[ "${elapsed}" -ge "${POD_TIMEOUT}" ]]; then
      fatal "timeout waiting for cluster readiness"
    fi
    if kubectl -n "${TARGET_NS}" get cluster "${CLUSTER_NAME}" -o jsonpath='{.status.readyInstances}' >/dev/null 2>&1; then
      local ready expected
      ready=$(kubectl -n "${TARGET_NS}" get cluster "${CLUSTER_NAME}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo 0)
      expected=$(kubectl -n "${TARGET_NS}" get cluster "${CLUSTER_NAME}" -o jsonpath='{.spec.instances}' 2>/dev/null || echo ${INSTANCES})
      if [[ -n "${ready}" && -n "${expected}" && "${ready}" -ge "${expected}" ]]; then
        log "Cluster reports ${ready}/${expected} ready instances"
        return 0
      fi
    fi
    local pods inst_pods ready_count need_count p
    pods=$(kubectl -n "${TARGET_NS}" get pods -l "cnpg.io/cluster=${CLUSTER_NAME}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    inst_pods=$(for p in ${pods}; do [[ "${p}" =~ ^${CLUSTER_NAME}-[0-9]+$ ]] && printf "%s\n" "${p}"; done || true)
    need_count=$(kubectl -n "${TARGET_NS}" get cluster "${CLUSTER_NAME}" -o jsonpath='{.spec.instances}' 2>/dev/null || echo ${INSTANCES})
    ready_count=0
    for p in ${inst_pods}; do
      if kubectl -n "${TARGET_NS}" get pod "${p}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
        ready_count=$((ready_count+1))
      fi
    done
    if [[ "${ready_count}" -ge "${need_count}" && "${need_count}" -gt 0 ]]; then
      log "Detected ${ready_count}/${need_count} instance pods Ready"
      return 0
    fi
    sleep 3
  done
}

wait_for_app_secret(){
  log "waiting for CNPG app secret ${CLUSTER_NAME}-app in ${TARGET_NS} (timeout ${SECRET_TIMEOUT}s)"
  local start now elapsed
  start=$(date +%s)
  while true; do
    now=$(date +%s)
    elapsed=$((now - start))
    if kubectl -n "${TARGET_NS}" get secret "${CLUSTER_NAME}-app" >/dev/null 2>&1; then
      log "secret ${CLUSTER_NAME}-app found"
      return 0
    fi
    if [[ "${elapsed}" -ge "${SECRET_TIMEOUT}" ]]; then
      fatal "timeout waiting for secret ${CLUSTER_NAME}-app"
    fi
    sleep 2
  done
}

render_pooler_manifest(){
  log "rendering Pooler manifest with resource defaults"
  mkdir -p "${MANIFEST_DIR}"
  cat > "${POOLER_FILE}" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: ${POOLER_NAME}
  namespace: ${TARGET_NS}
spec:
  cluster:
    name: ${CLUSTER_NAME}
  instances: ${POOLER_INSTANCES}
  type: rw
  pgbouncer:
    poolMode: transaction
    parameters:
      max_client_conn: "1000"
      default_pool_size: "25"
      min_pool_size: "5"
      reserve_pool_size: "10"
      server_idle_timeout: "600"
  template:
    spec:
      containers:
      - name: pgbouncer
        resources:
          requests:
            cpu: ${POOLER_CPU_REQUEST}
            memory: ${POOLER_MEM_REQUEST}
          limits:
            cpu: ${POOLER_CPU_LIMIT}
            memory: ${POOLER_MEM_LIMIT}
EOF
  log "pooler manifest written: ${POOLER_FILE}"
}

deploy_pooler(){
  log "applying Pooler manifest"
  kubectl apply -f "${POOLER_FILE}" >/dev/null
}

wait_for_pooler(){
  log "waiting for pooler readiness"
  local start now elapsed
  start=$(date +%s)
  while true; do
    now=$(date +%s)
    elapsed=$((now - start))
    local pods ready need svc
    pods=$(kubectl -n "${TARGET_NS}" get pods -l "cnpg.io/poolerName=${POOLER_NAME}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [[ -n "${pods}" ]]; then
      ready=$(for p in ${pods}; do kubectl -n "${TARGET_NS}" get pod "$p" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false; done | grep -c true || true)
      need=$(kubectl -n "${TARGET_NS}" get pooler "${POOLER_NAME}" -o jsonpath='{.spec.instances}' 2>/dev/null || echo ${POOLER_INSTANCES})
      if [[ "${ready}" -ge "${need}" && "${need}" -gt 0 ]]; then
        svc=$(kubectl -n "${TARGET_NS}" get svc "${POOLER_NAME}" -o jsonpath='{.metadata.name}' 2>/dev/null || true)
        if [[ -n "${svc}" ]]; then
          log "pooler ${POOLER_NAME} ready with service ${svc}"
          return 0
        fi
      fi
    fi
    if [[ "${elapsed}" -ge "${OPERATOR_TIMEOUT}" ]]; then
      fatal "timeout waiting for pooler readiness"
    fi
    sleep 3
  done
}

mask_uri(){ echo "$1" | sed -E 's#(:)[^:@]+(@)#:\*\*\*\*\*@#'; }

print_connection_uris(){
  log "printing masked pooler URIs"
  local user pw host port raw masked
  user=$(kubectl -n "${TARGET_NS}" get secret "${CLUSTER_NAME}-app" -o jsonpath='{.data.username}' | base64 -d)
  pw=$(kubectl -n "${TARGET_NS}" get secret "${CLUSTER_NAME}-app" -o jsonpath='{.data.password}' | base64 -d)
  host="${POOLER_NAME}.${TARGET_NS}"
  port=$(kubectl -n "${TARGET_NS}" get secret "${CLUSTER_NAME}-app" -o jsonpath='{.data.port}' | base64 -d || echo 5432)
  raw="postgresql://${user}:${pw}@${host}:${port}"
  masked=$(mask_uri "${raw}")
  printf "\nConnection URIs (masked):\n\n"
  printf "%s/flyte_admin\n" "${masked}"
  printf "%s/flyte_propeller\n" "${masked}"
  printf "%s/mlflow\n" "${masked}"
  printf "%s/rising_wave\n" "${masked}"
}

print_yaml_examples(){
  printf "\nExample Deployment env (safe, secretKeyRef):\n\n"
  cat <<'EOF'
env:
- name: DATABASE_URI
  valueFrom:
    secretKeyRef:
      name: postgres-cluster-app
      key: uri

- name: POSTGRES_USER
  valueFrom:
    secretKeyRef:
      name: postgres-cluster-app
      key: username
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: postgres-cluster-app
      key: password
- name: POSTGRES_HOST
  valueFrom:
    secretKeyRef:
      name: postgres-cluster-app
      key: host
- name: POSTGRES_PORT
  valueFrom:
    secretKeyRef:
      name: postgres-cluster-app
      key: port
EOF
}

persist_artifacts(){
  mkdir -p "${GENERATED_DIR}"
  cp "${CLUSTER_FILE}" "${GENERATED_DIR}/postgres_cluster.yaml" 2>/dev/null || true
  cp "${POOLER_FILE}" "${GENERATED_DIR}/postgres_pooler.yaml" 2>/dev/null || true
  print_connection_uris > "${GENERATED_DIR}/masked_pooler_uris.txt"
  log "artifacts persisted to ${GENERATED_DIR}"
}

run_crud_tests_via_pooler(){
  log "running CRUD tests via pooler"
  local user_key pw_key db pod start phase
  user_key='username'
  pw_key='password'
  for db in flyte_admin flyte_propeller mlflow rising_wave; do
    pod="e2e-pgtest-${db//_/-}"
    cat > "/tmp/${pod}.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${TARGET_NS}
spec:
  restartPolicy: Never
  containers:
  - name: psql
    image: postgres:16
    env:
    - name: PGUSER
      valueFrom:
        secretKeyRef:
          name: ${CLUSTER_NAME}-app
          key: ${user_key}
    - name: PGPASSWORD
      valueFrom:
        secretKeyRef:
          name: ${CLUSTER_NAME}-app
          key: ${pw_key}
    - name: PGHOST
      value: ${POOLER_NAME}.${TARGET_NS}
    - name: PGPORT
      valueFrom:
        secretKeyRef:
          name: ${CLUSTER_NAME}-app
          key: port
    - name: PGDATABASE
      value: ${db}
    command:
    - sh
    - -c
    - |
      psql -h "\${PGHOST}" -U "\${PGUSER}" -p "\${PGPORT}" -d "\${PGDATABASE}" -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS e2e_test (id SERIAL PRIMARY KEY, v TEXT);
INSERT INTO e2e_test(v) VALUES ('insert_test');
SELECT 'READ_AFTER_INSERT', * FROM e2e_test;
UPDATE e2e_test SET v='updated_test' WHERE v='insert_test';
SELECT 'READ_AFTER_UPDATE', * FROM e2e_test;
DELETE FROM e2e_test;
SELECT 'FINAL_COUNT', count(*) FROM e2e_test;
DROP TABLE e2e_test;
SQL
EOF
    kubectl apply -f "/tmp/${pod}.yaml" >/dev/null
    start=$(date +%s)
    while true; do
      phase=$(kubectl -n "${TARGET_NS}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      if [[ "${phase}" == "Succeeded" ]]; then
        log "pod ${pod} succeeded; logs:"
        kubectl -n "${TARGET_NS}" logs "${pod}" --tail=200 || true
        kubectl -n "${TARGET_NS}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true
        log "CRUD passed for ${db}"
        break
      fi
      if [[ "${phase}" == "Failed" ]]; then
        log "pod ${pod} failed; logs:"
        kubectl -n "${TARGET_NS}" logs "${pod}" --tail=200 || true
        kubectl -n "${TARGET_NS}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true
        fatal "CRUD failed for ${db}"
      fi
      if [[ $(( $(date +%s) - start )) -gt 180 ]]; then
        log "timeout waiting for ${pod}; logs:"
        kubectl -n "${TARGET_NS}" logs "${pod}" --tail=200 || true
        kubectl -n "${TARGET_NS}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true
        fatal "CRUD timeout for ${db}"
      fi
      sleep 2
    done
  done
  log "all CRUD tests via pooler passed"
}

main(){
  require_prereqs
  check_eks_csi
  ensure_storage_class
  install_cnpg_operator
  render_cluster_manifest
  deploy_cluster
  wait_for_cluster_ready
  wait_for_app_secret
  render_pooler_manifest
  deploy_pooler
  wait_for_pooler
  persist_artifacts
  print_connection_uris
  print_yaml_examples
  run_crud_tests_via_pooler
  printf "\n[SUCCESS] Full E2E complete. Cluster, pooler and CRUD tests passed.\n"
  printf "Generated artifacts (no secrets): %s\n" "${GENERATED_DIR}"
}

main