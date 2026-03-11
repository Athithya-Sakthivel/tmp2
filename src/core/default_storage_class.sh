#!/usr/bin/env bash
set -euo pipefail

readonly K8S_CLUSTER="${K8S_CLUSTER:-kind}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -A SC_NAME=( [kind]="local-path" [eks]="gp3" )
declare -A SC_PROVISIONER=( [kind]="rancher.io/local-path" [eks]="ebs.csi.aws.com" )
declare -A SC_BIND_MODE=( [kind]="Immediate" [eks]="WaitForFirstConsumer" )

if [[ ! "${SC_NAME[$K8S_CLUSTER]+isset}" ]]; then
  printf '[ERROR] Unsupported K8S_CLUSTER=%s\n' "$K8S_CLUSTER" >&2
  exit 1
fi

log(){ printf '[%s] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$K8S_CLUSTER" "$*" >&2; }
fatal(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
require_bin(){ command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }

ensure_storage_class(){
  local sc_name="${SC_NAME[$K8S_CLUSTER]}"
  local provisioner="${SC_PROVISIONER[$K8S_CLUSTER]}"
  local bind_mode="${SC_BIND_MODE[$K8S_CLUSTER]}"

  log "checking for StorageClass '${sc_name}'"
  if kubectl get storageclass "${sc_name}" >/dev/null 2>&1; then
    log "StorageClass '${sc_name}' already exists. Skipping creation."
    return 0
  fi

  log "StorageClass '${sc_name}' missing. Creating..."
  if [[ "$K8S_CLUSTER" == "kind" ]]; then
    log "installing local-path-provisioner for Kind"
    if ! kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml >/dev/null 2>&1; then
      fatal "failed to install local-path-provisioner"
    fi
    log "waiting for local-path-provisioner deployment"
    kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=120s >/dev/null || log "warning: provisioner rollout timed out, proceeding"
  else
    log "creating gp3 StorageClass for EKS"
    kubectl apply -f - <<EOF >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${sc_name}
provisioner: ${provisioner}
parameters:
  type: gp3
  encrypted: "true"
  fsType: ext4
reclaimPolicy: Delete
volumeBindingMode: ${bind_mode}
allowVolumeExpansion: true
EOF
  fi

  if kubectl get storageclass "${sc_name}" >/dev/null 2>&1; then
    log "StorageClass '${sc_name}' created successfully."
  else
    fatal "StorageClass '${sc_name}' verification failed after creation."
  fi
}

main(){
  require_bin kubectl
  log "starting storage class setup for K8S_CLUSTER=${K8S_CLUSTER}"
  ensure_storage_class
  log "storage class setup complete."
  cat <<EOFNEXT

[SUCCESS] StorageClass ready for K8S_CLUSTER=${K8S_CLUSTER}

NEXT STEP:
  Run the postgres rollout:
  K8S_CLUSTER=${K8S_CLUSTER} bash ${SCRIPT_DIR}/postgres_cluster.sh --rollout
EOFNEXT
}

case "${1:-}" in
  --setup) main ;;
  --help|-h) echo "Usage: $0 --setup" ; exit 0 ;;
  *) main ;;
esac