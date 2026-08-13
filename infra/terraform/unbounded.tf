locals {
  unbounded_version          = "v0.2.2"
  unbounded_manifests_sha256 = "5bcece9bd3f3569ae3204ae6044144f5b6c0a516c0d191ef0d9899b4c2a6124a"
}

resource "terraform_data" "unbounded_net" {
  triggers_replace = [
    terraform_data.managed_cni_ready.id,
    local.unbounded_version,
    local.unbounded_manifests_sha256,
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
          - assignmentEnabled: true
            cidrBlocks:
              - "$AKS_POD_CIDR"
            nodeBlockSizes:
              ipv4: 24
        manageCniPlugin: true
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
      AKS_NODE_COUNT="$(kubectl get nodes -o json | jq '[.items[] | select(.metadata.labels["kubernetes.azure.com/managedby"] != null or .metadata.labels["kubernetes.azure.com/cluster"] != null)] | length')"
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