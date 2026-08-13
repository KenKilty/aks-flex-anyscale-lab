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

lab_gate_managed_cilium_ready() {
  local artifact_dir="$1"
  local resource_group="${RESOURCE_GROUP_NAME:-${RG:-}}"
  local cluster_name="${CLUSTER_NAME:-${CLUSTER:-}}"
  local network_profile_json network_plugin pod_cidr
  local cilium_pods_json cilium_count

  lab_gate_need_cmd az
  lab_gate_need_cmd jq
  lab_gate_need_cmd kubectl
  lab_gate_artifact_dir "${artifact_dir}"
  [[ -n "${resource_group}" ]] || lab_gate_die "resource group name is not set for no-CNI validation"
  [[ -n "${cluster_name}" ]] || lab_gate_die "cluster name is not set for no-CNI validation"

  network_profile_json="${artifact_dir}/aks-network-profile.json"
  cilium_pods_json="${artifact_dir}/managed-cilium-pods-runtime.json"
  az aks show \
    --resource-group "${resource_group}" \
    --name "${cluster_name}" \
    --query networkProfile \
    --output json \
    --only-show-errors >"${network_profile_json}"

  network_plugin="$(jq -r '.networkPlugin // empty' "${network_profile_json}")"
  pod_cidr="$(jq -r '.podCidr // empty' "${network_profile_json}")"
  [[ "${network_plugin}" == "none" ]] || lab_gate_die "AKS networkPlugin must be none; found ${network_plugin:-unset}"
  kubectl -n kube-system get pods -l k8s-app=cilium -o json >"${cilium_pods_json}" 2>/dev/null || true
  cilium_count="$(jq -r '.items | length // 0' "${cilium_pods_json}")"
  [[ "${cilium_count}" -eq 0 ]] || lab_gate_die "AKS-managed Cilium is not allowed in the no-CNI lab flow; observed ${cilium_count} daemonset pod(s) (pods: ${cilium_pods_json})"
  [[ -z "${pod_cidr}" ]] || lab_gate_pass "AKS no-CNI network profile is active; podCidr=${pod_cidr:-unset}"
  lab_gate_pass "AKS no-CNI path is active for the Unbounded lab flow"
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

lab_gate_unbounded_flex_ready() {
  local artifact_dir="$1"
  local flex_pod_cidr="${TF_VAR_unbounded_flex_pod_cidr:-}"
  local cilium_pods_json sites_json peering_json nodes_json unbounded_pods_json
  local aks_node_name flex_node_pod_cidr flex_site_label flex_kube_proxy_label managed_node_cidrs
  local aks_unbounded_pod flex_unbounded_pod aks_cni_files aks_tc_filters flex_cni_files aks_cni_count flex_cni_count cilium_on_flex

  lab_gate_need_cmd jq
  lab_gate_need_cmd kubectl
  lab_gate_need_cmd python3
  lab_gate_artifact_dir "${artifact_dir}"
  [[ -n "${LAB_GATE_FLEX_NODE_NAME:-}" ]] || lab_gate_die "Flex node name is not set before Unbounded validation"
  [[ -n "${flex_pod_cidr}" ]] || lab_gate_die "TF_VAR_unbounded_flex_pod_cidr is not set for Unbounded validation"

  cilium_pods_json="${artifact_dir}/managed-cilium-pods-flex-check.json"
  sites_json="${artifact_dir}/unbounded-sites-runtime.json"
  peering_json="${artifact_dir}/unbounded-sitepeering-runtime.json"
  nodes_json="${artifact_dir}/unbounded-nodes-runtime.json"
  unbounded_pods_json="${artifact_dir}/unbounded-net-pods-runtime.json"
  aks_cni_files="${artifact_dir}/aks-active-cni-files.txt"
  aks_tc_filters="${artifact_dir}/aks-unbounded0-tc-filters.txt"
  flex_cni_files="${artifact_dir}/flex-active-cni-files.txt"

  kubectl get sites aks-managed flex -o json >"${sites_json}"
  jq -e --arg aks_pod_cidr "${TF_VAR_cilium_pod_cidr}" --arg flex_pod_cidr "${flex_pod_cidr}" '
    ([.items[] | select(.metadata.name == "aks-managed")][0] | .spec.manageCniPlugin == true and .spec.podCidrAssignments[0].assignmentEnabled == true and (.spec.podCidrAssignments[0].cidrBlocks | index($aks_pod_cidr) != null)) and
    ([.items[] | select(.metadata.name == "flex")][0] | .spec.manageCniPlugin == true and .spec.podCidrAssignments[0].assignmentEnabled == true and (.spec.podCidrAssignments[0].cidrBlocks | index($flex_pod_cidr) != null))
  ' "${sites_json}" >/dev/null || lab_gate_die "Unbounded Site CNI ownership or pod CIDRs do not match the no-CNI contract (sites: ${sites_json})"

  kubectl get sitepeering aks-flex-private-l3 -o json >"${peering_json}"
  jq -e '.spec.meshNodes == true and .spec.tunnelProtocol == "Auto" and (.spec.sites | index("aks-managed") != null) and (.spec.sites | index("flex") != null)' "${peering_json}" >/dev/null ||
    lab_gate_die "Unbounded SitePeering does not mesh aks-managed and flex with tunnelProtocol=Auto (peering: ${peering_json})"

  kubectl get nodes -o json >"${nodes_json}"
  managed_node_cidrs="$(jq -r '[.items[] | select(.metadata.labels["kubernetes.azure.com/managedby"] != null or .metadata.labels["kubernetes.azure.com/cluster"] != null) | .spec.podCIDR // ""] | .[]' "${nodes_json}")"
  [[ -n "${managed_node_cidrs}" ]] || lab_gate_die "managed AKS nodes have no Unbounded pod CIDRs"
  while IFS= read -r managed_node_cidr; do
    [[ -n "${managed_node_cidr}" ]] || lab_gate_die "a managed AKS node has no Unbounded pod CIDR"
    python3 -c 'import ipaddress, sys; child = ipaddress.ip_network(sys.argv[2]); assert child.prefixlen == 24 and child.subnet_of(ipaddress.ip_network(sys.argv[1]))' "${TF_VAR_cilium_pod_cidr}" "${managed_node_cidr}" ||
      lab_gate_die "managed AKS node podCIDR ${managed_node_cidr} is not a /24 inside ${TF_VAR_cilium_pod_cidr}"
  done <<<"${managed_node_cidrs}"
  flex_node_pod_cidr="$(jq -r --arg node "${LAB_GATE_FLEX_NODE_NAME}" '.items[] | select(.metadata.name == $node) | .spec.podCIDR // empty' "${nodes_json}")"
  flex_site_label="$(jq -r --arg node "${LAB_GATE_FLEX_NODE_NAME}" '.items[] | select(.metadata.name == $node) | .metadata.labels["unbounded-cloud.io/site"] // empty' "${nodes_json}")"
  flex_kube_proxy_label="$(jq -r --arg node "${LAB_GATE_FLEX_NODE_NAME}" '.items[] | select(.metadata.name == $node) | .metadata.labels["net.unbounded-cloud.io/kube-proxy"] // empty' "${nodes_json}")"
  [[ -n "${flex_node_pod_cidr}" ]] || lab_gate_die "Flex node ${LAB_GATE_FLEX_NODE_NAME} has no assigned podCIDR"
  python3 -c 'import ipaddress, sys; assert ipaddress.ip_network(sys.argv[2]).subnet_of(ipaddress.ip_network(sys.argv[1]))' "${flex_pod_cidr}" "${flex_node_pod_cidr}" ||
    lab_gate_die "Flex node podCIDR ${flex_node_pod_cidr} is outside ${flex_pod_cidr}"
  [[ "${flex_site_label}" == "flex" ]] || lab_gate_die "Flex node has Unbounded site label ${flex_site_label:-unset}; expected flex"
  [[ "${flex_kube_proxy_label}" == "managed" ]] || lab_gate_die "Flex node is not labeled for Unbounded-managed kube-proxy"

  kubectl -n unbounded-system rollout status daemonset/unbounded-net-node --timeout=5m >/dev/null
  kubectl -n unbounded-system rollout status daemonset/unbounded-net-kube-proxy-flex --timeout=5m >/dev/null
  kubectl -n unbounded-system get pods -o json >"${unbounded_pods_json}"
  flex_unbounded_pod="$(jq -r --arg node "${LAB_GATE_FLEX_NODE_NAME}" '[.items[] | select(.spec.nodeName == $node and .metadata.labels["app.kubernetes.io/name"] == "unbounded-net-node") | select(.status.phase == "Running") | select([.status.containerStatuses[]? | select(.ready != true)] | length == 0) | .metadata.name] | first // empty' "${unbounded_pods_json}")"
  [[ -n "${flex_unbounded_pod}" ]] || lab_gate_die "Unbounded node agent is not Ready on Flex node ${LAB_GATE_FLEX_NODE_NAME} (pods: ${unbounded_pods_json})"

  kubectl -n kube-system get pods -l k8s-app=cilium -o json >"${cilium_pods_json}" 2>/dev/null || true
  cilium_on_flex="$(jq -r --arg node "${LAB_GATE_FLEX_NODE_NAME}" '[.items[] | select(.spec.nodeName == $node)] | length' "${cilium_pods_json}")"
  [[ "${cilium_on_flex}" -eq 0 ]] || lab_gate_die "AKS-managed Cilium must not schedule on Flex node ${LAB_GATE_FLEX_NODE_NAME}"

  aks_node_name="$(jq -r --arg flex "${LAB_GATE_FLEX_NODE_NAME}" '[.items[] | select(.metadata.name != $flex) | select(.metadata.labels["kubernetes.azure.com/managedby"] != null or .metadata.labels["kubernetes.azure.com/cluster"] != null) | .metadata.name] | first // empty' "${nodes_json}")"
  [[ -n "${aks_node_name}" ]] || lab_gate_die "unable to select an AKS-managed node for CNI ownership validation"
  [[ "$(jq -r --arg node "${aks_node_name}" '.items[] | select(.metadata.name == $node) | .metadata.labels["net.unbounded-cloud.io/kube-proxy"] // empty' "${nodes_json}")" == "" ]] ||
    lab_gate_die "AKS-managed node ${aks_node_name} must not use Unbounded-managed kube-proxy"
  aks_unbounded_pod="$(jq -r --arg node "${aks_node_name}" '[.items[] | select(.spec.nodeName == $node and .metadata.labels["app.kubernetes.io/name"] == "unbounded-net-node") | .metadata.name] | first // empty' "${unbounded_pods_json}")"
  [[ -n "${aks_unbounded_pod}" ]] || lab_gate_die "unable to inspect CNI files on AKS-managed node ${aks_node_name}"
  kubectl -n unbounded-system exec "${aks_unbounded_pod}" -c node -- ip -4 route show "${TF_VAR_cilium_pod_cidr}" | grep -q 'dev unbounded0' ||
    lab_gate_die "Unbounded does not route managed AKS pod CIDR ${TF_VAR_cilium_pod_cidr} through unbounded0 on ${aks_node_name}"
  kubectl -n unbounded-system exec "${aks_unbounded_pod}" -c node -- tc filter show dev unbounded0 egress >"${aks_tc_filters}"
  grep -q 'unbounded_encap' "${aks_tc_filters}" || lab_gate_die "Unbounded does not own the unbounded0 TC egress filter on ${aks_node_name} (filters: ${aks_tc_filters})"
  ! grep -q 'cil_to_netdev' "${aks_tc_filters}" || lab_gate_die "managed Cilium attached to unbounded0 on ${aks_node_name} (filters: ${aks_tc_filters})"

  kubectl -n unbounded-system exec "${aks_unbounded_pod}" -c node -- sh -c 'find /host/etc/cni/net.d -maxdepth 1 -type f \( -name "*.conf" -o -name "*.conflist" -o -name "*.json" \) -print | sort' >"${aks_cni_files}"
  kubectl -n unbounded-system exec "${flex_unbounded_pod}" -c node -- sh -c 'find /host/etc/cni/net.d -maxdepth 1 -type f \( -name "*.conf" -o -name "*.conflist" -o -name "*.json" \) -print | sort' >"${flex_cni_files}"
  aks_cni_count="$(wc -l <"${aks_cni_files}" | tr -d ' ')"
  flex_cni_count="$(wc -l <"${flex_cni_files}" | tr -d ' ')"
  if [[ "${aks_cni_count}" -ne 1 ]] || ! grep -q '/10-unbounded.conflist$' "${aks_cni_files}"; then
    lab_gate_die "AKS-managed node ${aks_node_name} must have only 10-unbounded.conflist active (files: ${aks_cni_files})"
  fi
  if [[ "${flex_cni_count}" -ne 1 ]] || ! grep -q '/10-unbounded.conflist$' "${flex_cni_files}"; then
    lab_gate_die "Flex node ${LAB_GATE_FLEX_NODE_NAME} must have only 10-unbounded.conflist active (files: ${flex_cni_files})"
  fi

  lab_gate_pass "Unbounded owns the no-CNI AKS and Flex networking path"
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
  local aks_server_pod flex_server_pod aks_service flex_service aks_log flex_log service_log aks_describe flex_describe
  local aks_pod_ip flex_pod_ip aks_service_ip flex_service_ip aks_to_flex flex_to_aks aks_to_flex_service flex_to_aks_service

  lab_gate_need_cmd kubectl
  lab_gate_artifact_dir "${artifact_dir}"

  aks_server_pod="aks-route-server-$(date +%s)"
  flex_server_pod="flex-route-server-$(date +%s)"
  aks_service="aks-route-service-$(date +%s)"
  flex_service="flex-route-service-$(date +%s)"
  aks_log="${artifact_dir}/${aks_server_pod}.log"
  flex_log="${artifact_dir}/${flex_server_pod}.log"
  service_log="${artifact_dir}/unbounded-clusterip.log"
  aks_describe="${artifact_dir}/${aks_server_pod}-describe.txt"
  flex_describe="${artifact_dir}/${flex_server_pod}-describe.txt"

  kubectl delete pod "${aks_server_pod}" "${flex_server_pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete service "${aks_service}" "${flex_service}" --ignore-not-found >/dev/null 2>&1 || true
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
  name: ${aks_service}
spec:
  selector:
    app: ${aks_server_pod}
  ports:
    - port: 8080
      targetPort: 8080
---
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
  aks_service_ip="$(kubectl get service "${aks_service}" -o jsonpath='{.spec.clusterIP}')"
  flex_service_ip="$(kubectl get service "${flex_service}" -o jsonpath='{.spec.clusterIP}')"
  [[ -n "${aks_service_ip}" ]] || lab_gate_die "AKS route service has no ClusterIP"
  [[ -n "${flex_service_ip}" ]] || lab_gate_die "Flex route service has no ClusterIP"

  aks_to_flex="$(kubectl exec "${aks_server_pod}" -- wget -qO- -T 10 "http://${flex_pod_ip}:8080" 2>&1 || true)"
  flex_to_aks="$(kubectl exec "${flex_server_pod}" -- wget -qO- -T 10 "http://${aks_pod_ip}:8080" 2>&1 || true)"
  aks_to_flex_service="$(kubectl exec "${aks_server_pod}" -- wget -qO- -T 10 "http://${flex_service_ip}:8080" 2>&1 || true)"
  flex_to_aks_service="$(kubectl exec "${flex_server_pod}" -- wget -qO- -T 10 "http://${aks_service_ip}:8080" 2>&1 || true)"
  printf '%s\n' "${aks_to_flex}" >"${aks_log}"
  printf '%s\n' "${flex_to_aks}" >"${flex_log}"
  printf 'aks-to-flex-service=%s\nflex-to-aks-service=%s\n' "${aks_to_flex_service}" "${flex_to_aks_service}" >"${service_log}"

  kubectl delete pod "${aks_server_pod}" "${flex_server_pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete service "${aks_service}" "${flex_service}" --ignore-not-found >/dev/null 2>&1 || true
  [[ "${aks_to_flex}" == *"flex-route-ok"* ]] || lab_gate_die "AKS pod did not reach Flex pod ${flex_pod_ip}:8080 (output: ${aks_log})"
  [[ "${flex_to_aks}" == *"aks-route-ok"* ]] || lab_gate_die "Flex pod did not reach AKS pod ${aks_pod_ip}:8080 (output: ${flex_log})"
  [[ "${aks_to_flex_service}" == *"flex-route-ok"* ]] || lab_gate_die "AKS pod did not reach Flex ClusterIP ${flex_service_ip}:8080 (output: ${service_log})"
  [[ "${flex_to_aks_service}" == *"aks-route-ok"* ]] || lab_gate_die "Flex pod did not reach AKS ClusterIP ${aks_service_ip}:8080 (output: ${service_log})"

  lab_gate_pass "Unbounded connectivity: bilateral pod traffic and ClusterIP routing from AKS and Flex"
}