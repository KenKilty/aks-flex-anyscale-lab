#!/usr/bin/env bash
# shellcheck disable=SC2154

lab_gate_die() {
  if declare -F die >/dev/null 2>&1; then
    die "$1"
  fi
  printf 'error: %s\n' "$1" >&2
  exit 1
}

lab_gate_need_cmd() {
  command -v "$1" >/dev/null 2>&1 || lab_gate_die "missing required command: $1"
}

lab_gate_pass() {
  printf 'PASS %s\n' "$1"
}

lab_gate_artifact_dir() {
  local artifact_dir="$1"
  mkdir -p "${artifact_dir}"
}

lab_gate_anyscale_host_name() {
  local host="${1:-${ANYSCALE_HOST:-https://console.azure.anyscale.com}}"
  host="${host#http://}"
  host="${host#https://}"
  printf '%s\n' "${host%%/*}"
}

lab_gate_anyscale_operator_ready() {
  local artifact_dir="$1"
  local resource_group="${RESOURCE_GROUP_NAME:-${RG:-}}"
  local cluster_name="${CLUSTER_NAME:-${CLUSTER:-}}"
  local extension_name="${ANYSCALE_EXTENSION_NAME:-anyscale-operator}"
  local namespace="${TF_VAR_anyscale_operator_namespace:-anyscale-operator}"
  local ext_status_json operator_status_json provisioning_state install_message unhealthy_pods

  lab_gate_need_cmd az
  lab_gate_need_cmd jq
  lab_gate_need_cmd kubectl
  lab_gate_artifact_dir "${artifact_dir}"
  [[ -n "${resource_group}" ]] || lab_gate_die "resource group name is not set for Anyscale extension check"
  [[ -n "${cluster_name}" ]] || lab_gate_die "cluster name is not set for Anyscale extension check"

  ext_status_json="${artifact_dir}/anyscale-extension-status-runtime.json"
  operator_status_json="${artifact_dir}/anyscale-operator-pods-runtime.json"

  az k8s-extension show \
    --cluster-type managedClusters \
    --cluster-name "${cluster_name}" \
    --resource-group "${resource_group}" \
    --name "${extension_name}" \
    -o json >"${ext_status_json}" 2>/dev/null || {
    lab_gate_die "unable to read AKS extension status for ${extension_name} on ${cluster_name}"
  }

  provisioning_state="$(jq -r '.provisioningState // empty' "${ext_status_json}")"
  install_message="$(jq -r '.statuses[0].message // empty' "${ext_status_json}")"
  [[ "${provisioning_state}" == "Succeeded" ]] || lab_gate_die "Anyscale AKS extension ${extension_name} is ${provisioning_state:-unknown}. ${install_message:-No extension error message provided.}"

  kubectl -n "${namespace}" get pods -l app=anyscale-operator -o json >"${operator_status_json}"
  unhealthy_pods="$(jq -r '
    [.items[]
      | select(
          .status.phase != "Running" or
          ((.status.containerStatuses // []) | length) == 0 or
          ([.status.containerStatuses[]? | select(.ready != true)] | length) > 0
        )
      | .metadata.name]
    | join(",")' "${operator_status_json}")"

  [[ "$(jq -r '.items | length' "${operator_status_json}")" -ge 1 ]] || lab_gate_die "no anyscale-operator pods found in namespace ${namespace}"
  [[ -z "${unhealthy_pods}" ]] || lab_gate_die "anyscale-operator pods are not 3/3 Running in namespace ${namespace}: ${unhealthy_pods}"

  lab_gate_pass "Anyscale extension and operator pods ready"
}

lab_gate_anyscale_gateway_ready() {
  local artifact_dir="$1"
  local namespace="${TF_VAR_anyscale_operator_namespace:-anyscale-operator}"
  local gateway_name="${TF_VAR_anyscale_gateway_name:-anyscale-gateway}"
  local gateway_status_json programmed_status gateway_address

  lab_gate_need_cmd jq
  lab_gate_need_cmd kubectl
  lab_gate_artifact_dir "${artifact_dir}"

  gateway_status_json="${artifact_dir}/anyscale-gateway-runtime.json"
  kubectl -n "${namespace}" get gateway "${gateway_name}" -o json >"${gateway_status_json}" || {
    lab_gate_die "Gateway ${namespace}/${gateway_name} is missing"
  }

  programmed_status="$(jq -r '[.status.conditions[]? | select(.type == "Programmed") | .status] | last // ""' "${gateway_status_json}")"
  gateway_address="$(jq -r '.status.addresses[0].value // empty' "${gateway_status_json}")"

  [[ "${programmed_status}" == "True" ]] || lab_gate_die "Gateway ${gateway_name} is not Programmed=True"
  [[ -n "${gateway_address}" ]] || lab_gate_die "Gateway ${gateway_name} has no programmed address"

  lab_gate_pass "Gateway ${namespace}/${gateway_name} programmed at ${gateway_address}"
}

lab_gate_flex_node_ready() {
  local artifact_dir="$1"
  local node_json ready_count node_summary broadly_labeled_nodes

  lab_gate_need_cmd jq
  lab_gate_need_cmd kubectl
  lab_gate_artifact_dir "${artifact_dir}"

  node_json="${artifact_dir}/flex-node-preflight.json"
  kubectl get nodes -o json >"${node_json}"

  ready_count="$(jq -r \
    --arg pool "${AKS_FLEX_AGENT_POOL_NAME:-aksflexnodes}" \
    --arg region "${TF_VAR_flex_region}" \
    '[.items[]
      | select((.metadata.labels.agentpool // .metadata.labels["kubernetes.azure.com/agentpool"] // "") == $pool)
      | select((.metadata.labels["topology.kubernetes.io/region"] // .metadata.labels["failure-domain.beta.kubernetes.io/region"] // "") == $region)
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))]
      | length' "${node_json}")"

  LAB_GATE_FLEX_NODE_NAME="$(jq -r \
    --arg pool "${AKS_FLEX_AGENT_POOL_NAME:-aksflexnodes}" \
    --arg region "${TF_VAR_flex_region}" \
    '[.items[]
      | select((.metadata.labels.agentpool // .metadata.labels["kubernetes.azure.com/agentpool"] // "") == $pool)
      | select((.metadata.labels["topology.kubernetes.io/region"] // .metadata.labels["failure-domain.beta.kubernetes.io/region"] // "") == $region)
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      | .metadata.name]
      | first // ""' "${node_json}")"

  if [[ "${ready_count}" -lt 1 ]]; then
    node_summary="$(jq -r '
      [.items[]
        | {
            name: .metadata.name,
            pool: (.metadata.labels.agentpool // .metadata.labels["kubernetes.azure.com/agentpool"] // "unknown"),
            region: (.metadata.labels["topology.kubernetes.io/region"] // .metadata.labels["failure-domain.beta.kubernetes.io/region"] // "unknown"),
            ready: ([.status.conditions[]? | select(.type == "Ready") | .status] | first // "Unknown")
          }]
      | map("\(.name) pool=\(.pool) region=\(.region) ready=\(.ready)")
      | join("; ")' "${node_json}")"
    lab_gate_die "no Ready ${AKS_FLEX_AGENT_POOL_NAME:-aksflexnodes} nodes found in ${TF_VAR_flex_region}. Current nodes: ${node_summary}"
  fi

  broadly_labeled_nodes="$(jq -r \
    --arg pool "${AKS_FLEX_AGENT_POOL_NAME:-aksflexnodes}" \
    '[.items[]
      | select((.metadata.labels.agentpool // .metadata.labels["kubernetes.azure.com/agentpool"] // "") == $pool)
      | select(.metadata.labels["kubernetes.azure.com/cluster"] != null)
      | .metadata.name]
      | join(",")' "${node_json}")"
  [[ -z "${broadly_labeled_nodes}" ]] || lab_gate_die "Flex node(s) carry broad kubernetes.azure.com/cluster label and may attract AKS-managed DaemonSets: ${broadly_labeled_nodes}"

  lab_gate_pass "Flex node ${LAB_GATE_FLEX_NODE_NAME} Ready in ${TF_VAR_flex_region}"
}

lab_gate_kube_proxy_flex_ready() {
  local artifact_dir="$1"
  local daemonset_json desired ready

  lab_gate_need_cmd jq
  lab_gate_need_cmd kubectl
  lab_gate_artifact_dir "${artifact_dir}"

  daemonset_json="${artifact_dir}/kube-proxy-flex-runtime.json"
  kubectl -n kube-system rollout status daemonset/kube-proxy-flex --timeout=60s >/dev/null
  kubectl -n kube-system get daemonset kube-proxy-flex -o json >"${daemonset_json}"

  desired="$(jq -r '.status.desiredNumberScheduled // 0' "${daemonset_json}")"
  ready="$(jq -r '.status.numberReady // 0' "${daemonset_json}")"
  [[ "${desired}" -ge 1 ]] || lab_gate_die "kube-proxy-flex has no desired pods; Flex service routing is not programmed"
  [[ "${ready}" == "${desired}" ]] || lab_gate_die "kube-proxy-flex ready=${ready} desired=${desired}; Flex service routing is not ready"

  lab_gate_pass "kube-proxy-flex ready ${ready}/${desired}"
}

lab_gate_flex_dns_ready() {
  local artifact_dir="$1"
  local anyscale_dns_name="$2"
  local pod_name pod_log pod_describe

  lab_gate_need_cmd kubectl
  lab_gate_artifact_dir "${artifact_dir}"

  pod_name="dns-flex-proof-preflight-$(date +%s)"
  pod_log="${artifact_dir}/${pod_name}.log"
  pod_describe="${artifact_dir}/${pod_name}-describe.txt"

  kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
spec:
  restartPolicy: Never
  nodeSelector:
    agentpool: ${AKS_FLEX_AGENT_POOL_NAME:-aksflexnodes}
  tolerations:
    - key: aks-flex-node
      operator: Equal
      value: "true"
      effect: NoSchedule
  containers:
    - name: dns-flex-debug
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          set -eu
          cat /etc/resolv.conf
          nslookup ${anyscale_dns_name}
          nslookup kubernetes.default.svc.cluster.local
          sleep 5
EOF

  if ! kubectl wait --for=condition=Ready "pod/${pod_name}" --timeout=180s >/dev/null; then
    kubectl describe pod "${pod_name}" >"${pod_describe}" 2>&1 || true
    kubectl logs "${pod_name}" --tail=120 >"${pod_log}" 2>&1 || true
    kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    lab_gate_die "Flex DNS pod did not become Ready (describe: ${pod_describe}, logs: ${pod_log})"
  fi

  if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod_name}" --timeout=60s >/dev/null; then
    kubectl describe pod "${pod_name}" >"${pod_describe}" 2>&1 || true
    kubectl logs "${pod_name}" --tail=120 >"${pod_log}" 2>&1 || true
    kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    lab_gate_die "Flex DNS pod did not complete successfully (describe: ${pod_describe}, logs: ${pod_log})"
  fi

  kubectl logs "${pod_name}" --tail=120 >"${pod_log}"
  kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  grep -q 'svc.cluster.local' "${pod_log}" || lab_gate_die "Flex DNS resolv.conf did not include cluster search domains (logs: ${pod_log})"
  grep -q "${anyscale_dns_name}" "${pod_log}" || lab_gate_die "Flex DNS pod did not resolve ${anyscale_dns_name} (logs: ${pod_log})"
  grep -q 'kubernetes.default.svc.cluster.local' "${pod_log}" || lab_gate_die "Flex DNS pod did not resolve kubernetes.default.svc.cluster.local (logs: ${pod_log})"

  lab_gate_pass "Flex ClusterFirst DNS resolves Anyscale and Kubernetes service names"
}

lab_gate_flex_https_egress() {
  local artifact_dir="$1"
  local anyscale_dns_name="$2"
  local pod_name pod_log pod_describe

  lab_gate_need_cmd kubectl
  lab_gate_artifact_dir "${artifact_dir}"

  pod_name="flex-egress-debug-$(date +%s)"
  pod_log="${artifact_dir}/${pod_name}.log"
  pod_describe="${artifact_dir}/${pod_name}-describe.txt"

  kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
spec:
  restartPolicy: Never
  nodeSelector:
    agentpool: ${AKS_FLEX_AGENT_POOL_NAME:-aksflexnodes}
  tolerations:
    - key: aks-flex-node
      operator: Equal
      value: "true"
      effect: NoSchedule
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command:
        - sh
        - -c
        - |
          set -eu
          curl -fsSI https://${anyscale_dns_name} >/dev/null
          echo flex-egress-ok
EOF

  if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod_name}" --timeout=5m >/dev/null; then
    kubectl describe pod "${pod_name}" >"${pod_describe}" 2>&1 || true
    kubectl logs "${pod_name}" --tail=120 >"${pod_log}" 2>&1 || true
    kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    lab_gate_die "Flex HTTPS egress pod did not succeed (describe: ${pod_describe}, logs: ${pod_log})"
  fi

  kubectl logs "${pod_name}" --tail=120 >"${pod_log}"
  kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  grep -q 'flex-egress-ok' "${pod_log}" || lab_gate_die "Flex HTTPS egress pod did not emit flex-egress-ok (logs: ${pod_log})"

  lab_gate_pass "Flex pod HTTPS egress reaches ${anyscale_dns_name}"
}

lab_gate_aks_to_flex_line_of_sight() {
  local artifact_dir="$1"
  local server_pod client_pod server_log client_log server_describe client_describe flex_pod_ip

  lab_gate_need_cmd kubectl
  lab_gate_artifact_dir "${artifact_dir}"

  server_pod="flex-route-server-$(date +%s)"
  client_pod="aks-to-flex-client-$(date +%s)"
  server_log="${artifact_dir}/${server_pod}.log"
  client_log="${artifact_dir}/${client_pod}.log"
  server_describe="${artifact_dir}/${server_pod}-describe.txt"
  client_describe="${artifact_dir}/${client_pod}-describe.txt"

  kubectl delete pod "${server_pod}" "${client_pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${server_pod}
spec:
  restartPolicy: Never
  nodeSelector:
    agentpool: ${AKS_FLEX_AGENT_POOL_NAME:-aksflexnodes}
  tolerations:
    - key: aks-flex-node
      operator: Equal
      value: "true"
      effect: NoSchedule
  containers:
    - name: server
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          mkdir -p /www
          echo flex-route-ok > /www/index.html
          httpd -f -p 8080 -h /www
EOF

  if ! kubectl wait --for=condition=Ready "pod/${server_pod}" --timeout=180s >/dev/null; then
    kubectl describe pod "${server_pod}" >"${server_describe}" 2>&1 || true
    kubectl logs "${server_pod}" --tail=120 >"${server_log}" 2>&1 || true
    kubectl delete pod "${server_pod}" "${client_pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    lab_gate_die "Flex route server did not become Ready (describe: ${server_describe}, logs: ${server_log})"
  fi

  flex_pod_ip="$(kubectl get pod "${server_pod}" -o jsonpath='{.status.podIP}')"
  [[ -n "${flex_pod_ip}" ]] || lab_gate_die "Flex route server has no pod IP"

  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${client_pod}
spec:
  restartPolicy: Never
  nodeSelector:
    agentpool: cpu
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command:
        - sh
        - -c
        - |
          set -eu
          curl -fsS http://${flex_pod_ip}:8080
EOF

  if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${client_pod}" --timeout=10m >/dev/null; then
    kubectl describe pod "${client_pod}" >"${client_describe}" 2>&1 || true
    kubectl logs "${client_pod}" --tail=120 >"${client_log}" 2>&1 || true
    kubectl delete pod "${server_pod}" "${client_pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    lab_gate_die "AKS-to-Flex client did not reach ${flex_pod_ip}:8080 (describe: ${client_describe}, logs: ${client_log})"
  fi

  kubectl logs "${client_pod}" --tail=120 >"${client_log}"
  kubectl logs "${server_pod}" --tail=120 >"${server_log}" 2>&1 || true
  kubectl delete pod "${server_pod}" "${client_pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  grep -q 'flex-route-ok' "${client_log}" || lab_gate_die "AKS-to-Flex client did not receive flex-route-ok (logs: ${client_log})"

  lab_gate_pass "AKS pod reached Flex pod ${flex_pod_ip}:8080"
}