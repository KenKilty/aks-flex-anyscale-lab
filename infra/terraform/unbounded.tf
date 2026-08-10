locals {
  unbounded_version                    = "v0.2.2"
  unbounded_manifests_sha256           = "5bcece9bd3f3569ae3204ae6044144f5b6c0a516c0d191ef0d9899b4c2a6124a"
  unbounded_compatibility_revision     = 2
  unbounded_aks_route_placeholder_cidr = "192.0.2.255/32"
}

resource "terraform_data" "unbounded_net" {
  triggers_replace = [
    terraform_data.managed_cni_ready.id,
    local.unbounded_version,
    local.unbounded_manifests_sha256,
    local.unbounded_compatibility_revision,
    local.unbounded_aks_route_placeholder_cidr,
    var.cilium_pod_cidr,
    var.unbounded_flex_pod_cidr,
    var.flex_subnet_cidr,
    var.subnet_cidrs.aks_nodes,
  ]

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]

    environment = {
      AKS_CLUSTER_NAME           = module.aks.cluster_name
      AKS_NODE_CIDR              = var.subnet_cidrs.aks_nodes
      AKS_POD_CIDR               = var.cilium_pod_cidr
      AKS_ROUTE_PLACEHOLDER_CIDR = local.unbounded_aks_route_placeholder_cidr
      AKS_RESOURCE_GROUP         = azurerm_resource_group.this.name
      FLEX_NODE_CIDR             = var.flex_subnet_cidr
      FLEX_POD_CIDR              = var.unbounded_flex_pod_cidr
      UNBOUNDED_MANIFESTS_SHA256 = local.unbounded_manifests_sha256
      UNBOUNDED_VERSION          = local.unbounded_version
    }

    command = <<-EOT
      set -euo pipefail

      az aks get-credentials \
        --resource-group "$AKS_RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --overwrite-existing \
        --only-show-errors >/dev/null
      kubelogin convert-kubeconfig -l azurecli >/dev/null

      WORK_DIR="$(mktemp -d)"
      trap 'rm -rf "$WORK_DIR"' EXIT
      ARCHIVE="$WORK_DIR/unbounded-manifests-$UNBOUNDED_VERSION.tar.gz"
      curl -fsSLo "$ARCHIVE" \
        "https://github.com/Azure/unbounded/releases/download/$UNBOUNDED_VERSION/unbounded-manifests-$UNBOUNDED_VERSION.tar.gz"
      printf '%s  %s\n' "$UNBOUNDED_MANIFESTS_SHA256" "$ARCHIVE" | shasum -a 256 -c -
      tar -xzf "$ARCHIVE" -C "$WORK_DIR"
      MANIFEST_ROOT="$WORK_DIR/unbounded-manifests-$UNBOUNDED_VERSION"

      kubectl apply --server-side --force-conflicts \
        -f "$MANIFEST_ROOT/machina/crd/unbounded-cloud.io_sites.yaml"
      kubectl apply --server-side --force-conflicts \
        -f "$MANIFEST_ROOT/net/00-namespace.yaml" \
        -f "$MANIFEST_ROOT/net/01-configmap.yaml" \
        -f "$MANIFEST_ROOT/net/crd"
      kubectl wait --for=condition=Established \
        crd/sites.unbounded-cloud.io \
        crd/sitepeerings.net.unbounded-cloud.io \
        --timeout=5m
      kubectl apply --server-side --force-conflicts -f "$MANIFEST_ROOT/net/controller"
      kubectl -n unbounded-system rollout status deployment/unbounded-net-controller --timeout=10m

      kubectl apply --server-side --force-conflicts -f - <<EOF
      apiVersion: unbounded-cloud.io/v1alpha3
      kind: Site
      metadata:
        name: aks-managed
      spec:
        nodeCidrs:
          - "$AKS_NODE_CIDR"
        podCidrAssignments:
          - assignmentEnabled: false
            cidrBlocks:
              - "$AKS_ROUTE_PLACEHOLDER_CIDR"
        manageCniPlugin: false
      ---
      apiVersion: unbounded-cloud.io/v1alpha3
      kind: Site
      metadata:
        name: flex
      spec:
        nodeCidrs:
          - "$FLEX_NODE_CIDR"
        podCidrAssignments:
          - assignmentEnabled: true
            cidrBlocks:
              - "$FLEX_POD_CIDR"
            nodeBlockSizes:
              ipv4: 24
        manageCniPlugin: true
      ---
      apiVersion: net.unbounded-cloud.io/v1alpha1
      kind: SitePeering
      metadata:
        name: aks-flex-private-l3
      spec:
        sites:
          - aks-managed
          - flex
        meshNodes: true
        tunnelProtocol: Auto
      EOF

      kubectl apply --server-side --force-conflicts -f - <<'EOF'
      apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: unbounded-aks-overlay-metadata
        namespace: unbounded-system
      ---
      apiVersion: rbac.authorization.k8s.io/v1
      kind: ClusterRole
      metadata:
        name: unbounded-aks-overlay-metadata
      rules:
        - apiGroups: [""]
          resources: ["nodes"]
          verbs: ["get", "patch"]
      ---
      apiVersion: rbac.authorization.k8s.io/v1
      kind: ClusterRoleBinding
      metadata:
        name: unbounded-aks-overlay-metadata
      roleRef:
        apiGroup: rbac.authorization.k8s.io
        kind: ClusterRole
        name: unbounded-aks-overlay-metadata
      subjects:
        - kind: ServiceAccount
          name: unbounded-aks-overlay-metadata
          namespace: unbounded-system
      ---
      apiVersion: apps/v1
      kind: DaemonSet
      metadata:
        name: unbounded-aks-overlay-metadata
        namespace: unbounded-system
        labels:
          app.kubernetes.io/name: unbounded-aks-overlay-metadata
          app.kubernetes.io/component: azure-cni-overlay-compatibility
      spec:
        selector:
          matchLabels:
            app.kubernetes.io/name: unbounded-aks-overlay-metadata
        template:
          metadata:
            annotations:
              kubernetes.azure.com/set-kube-service-host-fqdn: "true"
            labels:
              app.kubernetes.io/name: unbounded-aks-overlay-metadata
              app.kubernetes.io/component: azure-cni-overlay-compatibility
          spec:
            serviceAccountName: unbounded-aks-overlay-metadata
            affinity:
              nodeAffinity:
                requiredDuringSchedulingIgnoredDuringExecution:
                  nodeSelectorTerms:
                    - matchExpressions:
                        - key: kubernetes.azure.com/managedby
                          operator: Exists
                    - matchExpressions:
                        - key: kubernetes.azure.com/cluster
                          operator: Exists
            tolerations:
              - operator: Exists
            containers:
              - name: publisher
                image: curlimages/curl:8.10.1
                imagePullPolicy: IfNotPresent
                command:
                  - sh
                  - -c
                  - |
                    set -eu
                    POD_CIDR="$(printf '%s\n' "$POD_IP" | awk -F. 'NF == 4 {print $1 "." $2 "." $3 ".0/24"}')"
                    test -n "$POD_CIDR"
                    TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
                    APISERVER="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT_HTTPS"
                    PATCH="{\"spec\":{\"podCIDR\":\"$POD_CIDR\",\"podCIDRs\":[\"$POD_CIDR\"]}}"
                    until curl --fail --silent --show-error \
                      --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
                      --header "Authorization: Bearer $TOKEN" \
                      --header 'Content-Type: application/merge-patch+json' \
                      --request PATCH \
                      --data "$PATCH" \
                      "$APISERVER/api/v1/nodes/$NODE_NAME" >/dev/null; do
                      sleep 5
                    done
                    while true; do sleep 3600; done
                env:
                  - name: NODE_NAME
                    valueFrom:
                      fieldRef:
                        fieldPath: spec.nodeName
                  - name: POD_IP
                    valueFrom:
                      fieldRef:
                        fieldPath: status.podIP
                resources:
                  requests:
                    cpu: 5m
                    memory: 16Mi
                  limits:
                    memory: 32Mi
                securityContext:
                  allowPrivilegeEscalation: false
                  capabilities:
                    drop: ["ALL"]
                  readOnlyRootFilesystem: true
                  runAsNonRoot: true
                  runAsUser: 100
                volumeMounts:
                  - name: tmp
                    mountPath: /tmp
            volumes:
              - name: tmp
                emptyDir: {}
      EOF
      kubectl -n unbounded-system rollout status daemonset/unbounded-aks-overlay-metadata --timeout=10m

      AKS_NODE_COUNT="$(kubectl get nodes -o json | jq '[.items[] | select(.metadata.labels["kubernetes.azure.com/managedby"] != null or .metadata.labels["kubernetes.azure.com/cluster"] != null)] | length')"
      for ATTEMPT in $(seq 1 60); do
        VALID_CIDR_COUNT="$(kubectl get nodes -o json | jq --arg cidr "$AKS_POD_CIDR" '
          def ipv4_to_int: split(".") | map(tonumber) | .[0] * 16777216 + .[1] * 65536 + .[2] * 256 + .[3];
          ($cidr | split("/")[0] | ipv4_to_int) as $base |
          [.items[]
            | select(.metadata.labels["kubernetes.azure.com/managedby"] != null or .metadata.labels["kubernetes.azure.com/cluster"] != null)
            | select(.spec.podCIDR != null and (.spec.podCIDR | endswith("/24")))
            | select(((.spec.podCIDR | split("/")[0] | ipv4_to_int) >= $base) and ((.spec.podCIDR | split("/")[0] | ipv4_to_int) < ($base + 65536)))]
          | length')"
        [[ "$VALID_CIDR_COUNT" -eq "$AKS_NODE_COUNT" ]] && break
        sleep 5
      done
      [[ "$VALID_CIDR_COUNT" -eq "$AKS_NODE_COUNT" ]] || {
        kubectl get nodes -o custom-columns='NAME:.metadata.name,PODCIDR:.spec.podCIDR'
        printf 'error: Azure overlay metadata publisher did not set one /24 podCIDR inside %s on every managed AKS node\n' "$AKS_POD_CIDR" >&2
        exit 1
      }

      kubectl -n kube-system patch configmap cilium-config --type merge \
        -p '{"data":{"devices":"eth0,!unbounded0"}}'
      kubectl -n kube-system rollout restart daemonset/cilium >/dev/null
      kubectl -n kube-system rollout status daemonset/cilium --timeout=10m

      kubectl apply --server-side --force-conflicts -f "$MANIFEST_ROOT/net/node"
      kubectl -n unbounded-system rollout status daemonset/unbounded-net-node --timeout=10m
      kubectl -n unbounded-system rollout restart daemonset/unbounded-net-node >/dev/null
      kubectl -n unbounded-system rollout status daemonset/unbounded-net-node --timeout=10m
      for NODE in $(kubectl get nodes -o json | jq -r '.items[] | select(.metadata.labels["kubernetes.azure.com/managedby"] != null or .metadata.labels["kubernetes.azure.com/cluster"] != null) | .metadata.name'); do
        NODE_POD="$(kubectl -n unbounded-system get pods -l app.kubernetes.io/name=unbounded-net-node --field-selector "spec.nodeName=$NODE" -o jsonpath='{.items[0].metadata.name}')"
        TC_FILTERS="$(kubectl -n unbounded-system exec "$NODE_POD" -c node -- tc filter show dev unbounded0 egress)"
        grep -q 'unbounded_encap' <<<"$TC_FILTERS" || {
          printf '%s\n' "$TC_FILTERS"
          printf 'error: Unbounded does not own the unbounded0 TC egress filter on managed node %s\n' "$NODE" >&2
          exit 1
        }
        ! grep -q 'cil_to_netdev' <<<"$TC_FILTERS" || {
          printf '%s\n' "$TC_FILTERS"
          printf 'error: managed Cilium attached to unbounded0 on node %s\n' "$NODE" >&2
          exit 1
        }
      done
      for ATTEMPT in $(seq 1 60); do
        ADVERTISED_NODE_COUNT="$(kubectl get sitenodeslices -o json | jq '[.items[] | select(.siteName == "aks-managed") | .nodes[] | select((.podCIDRs // []) | length == 1)] | length')"
        [[ "$ADVERTISED_NODE_COUNT" -eq "$AKS_NODE_COUNT" ]] && break
        sleep 5
      done
      [[ "$ADVERTISED_NODE_COUNT" -eq "$AKS_NODE_COUNT" ]] || {
        kubectl get sitenodeslices -o yaml
        printf 'error: Unbounded did not advertise every managed AKS node podCIDR\n' >&2
        exit 1
      }
      kubectl get sites,sitenodeslices,sitepeerings -o wide
    EOT
  }

  depends_on = [terraform_data.managed_cni_ready]
}