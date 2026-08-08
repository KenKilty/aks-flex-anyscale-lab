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

lab_gate_collect_pod_logs() {
  local pod_name="$1"
  local pod_log="$2"

  for _ in {1..5}; do
    if kubectl logs "${pod_name}" --tail=120 >"${pod_log}" 2>&1; then
      return 0
    fi
    sleep 3
  done

  return 1
}

lab_gate_anyscale_host_name() {
  printf '%s\n' "console.azure.anyscale.com"
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

lab_gate_cilium_ready() {
  local artifact_dir="$1"
  local resource_group="${RESOURCE_GROUP_NAME:-${RG:-}}"
  local cluster_name="${CLUSTER_NAME:-${CLUSTER:-}}"
  local cilium_pod_cidr="${TF_VAR_cilium_pod_cidr:-}"
  local network_profile_json cilium_values_json network_plugin pod_cidr

  lab_gate_need_cmd az
  lab_gate_need_cmd helm
  lab_gate_need_cmd jq
  lab_gate_need_cmd kubectl
  lab_gate_artifact_dir "${artifact_dir}"
  [[ -n "${resource_group}" ]] || lab_gate_die "resource group name is not set for Cilium validation"
  [[ -n "${cluster_name}" ]] || lab_gate_die "cluster name is not set for Cilium validation"
  [[ -n "${cilium_pod_cidr}" ]] || lab_gate_die "TF_VAR_cilium_pod_cidr is not set for Cilium validation"

  network_profile_json="${artifact_dir}/aks-network-profile.json"
  cilium_values_json="${artifact_dir}/cilium-values-runtime.json"
  az aks show \
    --resource-group "${resource_group}" \
    --name "${cluster_name}" \
    --query networkProfile \
    --output json \
    --only-show-errors >"${network_profile_json}"
  helm -n kube-system get values cilium --output json >"${cilium_values_json}"

  network_plugin="$(jq -r '.networkPlugin // empty' "${network_profile_json}")"
  pod_cidr="$(jq -r '.podCidr // empty' "${network_profile_json}")"
  [[ "${network_plugin}" == "none" ]] || lab_gate_die "AKS networkPlugin must be none for unmanaged Cilium; found ${network_plugin:-unset}"
  [[ "${pod_cidr}" == "${cilium_pod_cidr}" ]] || lab_gate_die "AKS podCidr must match TF_VAR_cilium_pod_cidr=${cilium_pod_cidr}; found ${pod_cidr:-unset}"

  jq -e --arg cilium_pod_cidr "${cilium_pod_cidr}" '
    .ipam.mode == "cluster-pool" and
    (.ipam.operator.clusterPoolIPv4PodCIDRList | index($cilium_pod_cidr)) != null and
    .ipam.operator.clusterPoolIPv4MaskSize == 24 and
    .routingMode == "tunnel" and
    .tunnelProtocol == "vxlan" and
    .kubeProxyReplacement == true and
    (.bpf.masquerade? // null) == null
  ' "${cilium_values_json}" >/dev/null || lab_gate_die "Cilium Helm values do not match the upstream cluster-pool, VXLAN, and kube-proxy-replacement configuration (values: ${cilium_values_json})"

  kubectl -n kube-system rollout status daemonset/cilium --timeout=10m >/dev/null
  kubectl -n kube-system rollout status daemonset/cilium-envoy --timeout=10m >/dev/null
  lab_gate_pass "Unmanaged upstream Cilium cluster-pool IPAM and VXLAN ready"
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

lab_gate_cilium_flex_ready() {
  local artifact_dir="$1"
  local cilium_pods_json cilium_ready envoy_ready

  lab_gate_need_cmd jq
  lab_gate_need_cmd kubectl
  lab_gate_artifact_dir "${artifact_dir}"
  [[ -n "${LAB_GATE_FLEX_NODE_NAME:-}" ]] || lab_gate_die "Flex node name is not set before Cilium validation"

  cilium_pods_json="${artifact_dir}/cilium-flex-pods-runtime.json"
  kubectl -n kube-system rollout status daemonset/cilium --timeout=5m >/dev/null
  kubectl -n kube-system rollout status daemonset/cilium-envoy --timeout=5m >/dev/null
  kubectl -n kube-system get pods -o json >"${cilium_pods_json}"

  cilium_ready="$(jq -r --arg node "${LAB_GATE_FLEX_NODE_NAME}" '
    [.items[]
      | select(.spec.nodeName == $node and .metadata.labels["k8s-app"] == "cilium")
      | select(.status.phase == "Running")
      | select((.status.containerStatuses // []) | length > 0)
      | select([.status.containerStatuses[]? | select(.ready != true)] | length == 0)]
    | length' "${cilium_pods_json}")"
  envoy_ready="$(jq -r --arg node "${LAB_GATE_FLEX_NODE_NAME}" '
    [.items[]
      | select(.spec.nodeName == $node and .metadata.labels["k8s-app"] == "cilium-envoy")
      | select(.status.phase == "Running")
      | select((.status.containerStatuses // []) | length > 0)
      | select([.status.containerStatuses[]? | select(.ready != true)] | length == 0)]
    | length' "${cilium_pods_json}")"

  [[ "${cilium_ready}" -ge 1 ]] || lab_gate_die "Cilium agent is not Ready on Flex node ${LAB_GATE_FLEX_NODE_NAME} (pods: ${cilium_pods_json})"
  [[ "${envoy_ready}" -ge 1 ]] || lab_gate_die "Cilium Envoy is not Ready on Flex node ${LAB_GATE_FLEX_NODE_NAME} (pods: ${cilium_pods_json})"

  lab_gate_pass "Cilium agent and Envoy Ready on Flex node ${LAB_GATE_FLEX_NODE_NAME}"
}

lab_gate_flex_dns_ready() {
  local artifact_dir="$1"
  local anyscale_dns_name="$2"
  local pod_name pod_log pod_describe

  lab_gate_need_cmd kubectl
  lab_gate_artifact_dir "${artifact_dir}"

  pod_name="dns-flex-workload-preflight-$(date +%s)"
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
    lab_gate_collect_pod_logs "${pod_name}" "${pod_log}" || true
    kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    lab_gate_die "Flex DNS pod did not become Ready (describe: ${pod_describe}, logs: ${pod_log})"
  fi

  if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod_name}" --timeout=60s >/dev/null; then
    kubectl describe pod "${pod_name}" >"${pod_describe}" 2>&1 || true
    lab_gate_collect_pod_logs "${pod_name}" "${pod_log}" || true
    kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    lab_gate_die "Flex DNS pod did not complete successfully (describe: ${pod_describe}, logs: ${pod_log})"
  fi

  lab_gate_collect_pod_logs "${pod_name}" "${pod_log}" || lab_gate_die "Flex DNS pod logs could not be collected after completion (logs: ${pod_log})"
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
    lab_gate_collect_pod_logs "${pod_name}" "${pod_log}" || true
    kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    lab_gate_die "Flex HTTPS egress pod did not succeed (describe: ${pod_describe}, logs: ${pod_log})"
  fi

  lab_gate_collect_pod_logs "${pod_name}" "${pod_log}" || lab_gate_die "Flex HTTPS egress pod logs could not be collected after completion (logs: ${pod_log})"
  kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  grep -q 'flex-egress-ok' "${pod_log}" || lab_gate_die "Flex HTTPS egress pod did not emit flex-egress-ok (logs: ${pod_log})"

  lab_gate_pass "Flex pod HTTPS egress reaches ${anyscale_dns_name}"
}

lab_gate_aks_to_flex_line_of_sight() {
  local artifact_dir="$1"
  local aks_server_pod flex_server_pod flex_service aks_log flex_log aks_describe flex_describe aks_pod_ip flex_pod_ip flex_service_ip aks_to_flex flex_to_aks aks_to_service

  lab_gate_need_cmd kubectl
  lab_gate_artifact_dir "${artifact_dir}"

  aks_server_pod="aks-route-server-$(date +%s)"
  flex_server_pod="flex-route-server-$(date +%s)"
  flex_service="flex-route-service-$(date +%s)"
  aks_log="${artifact_dir}/${aks_server_pod}.log"
  flex_log="${artifact_dir}/${flex_server_pod}.log"
  aks_describe="${artifact_dir}/${aks_server_pod}-describe.txt"
  flex_describe="${artifact_dir}/${flex_server_pod}-describe.txt"

  kubectl delete pod "${aks_server_pod}" "${flex_server_pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete service "${flex_service}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${aks_server_pod}
  labels:
    app: ${aks_server_pod}
spec:
  restartPolicy: Never
  nodeSelector:
    agentpool: cpu
  containers:
    - name: server
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          mkdir -p /www
          echo aks-route-ok > /www/index.html
          httpd -f -p 8080 -h /www
---
apiVersion: v1
kind: Pod
metadata:
  name: ${flex_server_pod}
  labels:
    app: ${flex_server_pod}
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

  if ! kubectl wait --for=condition=Ready "pod/${aks_server_pod}" --timeout=180s >/dev/null; then
    kubectl describe pod "${aks_server_pod}" >"${aks_describe}" 2>&1 || true
    kubectl logs "${aks_server_pod}" --tail=120 >"${aks_log}" 2>&1 || true
    kubectl delete pod "${aks_server_pod}" "${flex_server_pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    lab_gate_die "AKS route server did not become Ready (describe: ${aks_describe}, logs: ${aks_log})"
  fi

  if ! kubectl wait --for=condition=Ready "pod/${flex_server_pod}" --timeout=180s >/dev/null; then
    kubectl describe pod "${flex_server_pod}" >"${flex_describe}" 2>&1 || true
    kubectl logs "${flex_server_pod}" --tail=120 >"${flex_log}" 2>&1 || true
    kubectl delete pod "${aks_server_pod}" "${flex_server_pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    lab_gate_die "Flex route server did not become Ready (describe: ${flex_describe}, logs: ${flex_log})"
  fi

  aks_pod_ip="$(kubectl get pod "${aks_server_pod}" -o jsonpath='{.status.podIP}')"
  flex_pod_ip="$(kubectl get pod "${flex_server_pod}" -o jsonpath='{.status.podIP}')"
  [[ -n "${aks_pod_ip}" ]] || lab_gate_die "AKS route server has no pod IP"
  [[ -n "${flex_pod_ip}" ]] || lab_gate_die "Flex route server has no pod IP"

  kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${flex_service}
spec:
  selector:
    app: ${flex_server_pod}
  ports:
    - port: 8080
      targetPort: 8080
EOF
  flex_service_ip="$(kubectl get service "${flex_service}" -o jsonpath='{.spec.clusterIP}')"
  [[ -n "${flex_service_ip}" ]] || lab_gate_die "Flex route service has no ClusterIP"

  aks_to_flex="$(kubectl exec "${aks_server_pod}" -- wget -qO- -T 10 "http://${flex_pod_ip}:8080" 2>&1 || true)"
  flex_to_aks="$(kubectl exec "${flex_server_pod}" -- wget -qO- -T 10 "http://${aks_pod_ip}:8080" 2>&1 || true)"
  aks_to_service="$(kubectl exec "${aks_server_pod}" -- wget -qO- -T 10 "http://${flex_service_ip}:8080" 2>&1 || true)"
  printf '%s\n' "${aks_to_flex}" >"${aks_log}"
  printf '%s\n' "${flex_to_aks}" >"${flex_log}"

  kubectl delete pod "${aks_server_pod}" "${flex_server_pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete service "${flex_service}" --ignore-not-found >/dev/null 2>&1 || true
  [[ "${aks_to_flex}" == *"flex-route-ok"* ]] || lab_gate_die "AKS pod did not reach Flex pod ${flex_pod_ip}:8080 (output: ${aks_log})"
  [[ "${flex_to_aks}" == *"aks-route-ok"* ]] || lab_gate_die "Flex pod did not reach AKS pod ${aks_pod_ip}:8080 (output: ${flex_log})"
  [[ "${aks_to_service}" == *"flex-route-ok"* ]] || lab_gate_die "AKS pod did not reach Flex ClusterIP ${flex_service_ip}:8080 (output: ${aks_log})"

  lab_gate_pass "Upstream Cilium connectivity: AKS and Flex pods exchanged traffic and AKS reached Flex ClusterIP ${flex_service_ip}:8080"
}