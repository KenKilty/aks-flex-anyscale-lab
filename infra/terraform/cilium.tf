locals {
  managed_istio_gateway_api_managed_cluster_api_type = "Microsoft.ContainerService/managedClusters@2026-03-02-preview"
}

resource "terraform_data" "cilium" {
  triggers_replace = [
    module.aks.aks_provisioning_validation,
    var.cilium_pod_cidr,
    var.service_cidr,
  ]

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]

    environment = {
      AKS_CLUSTER_NAME   = module.aks.cluster_name
      AKS_RESOURCE_GROUP = azurerm_resource_group.this.name
      CILIUM_POD_CIDR    = var.cilium_pod_cidr
    }

    command = <<-EOT
      set -euo pipefail

      NETWORK_PLUGIN="$(az aks show \
        --resource-group "$AKS_RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --query 'networkProfile.networkPlugin' \
        -o tsv)"
      POD_CIDR="$(az aks show \
        --resource-group "$AKS_RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --query 'networkProfile.podCidr' \
        -o tsv)"
      if [[ "$NETWORK_PLUGIN" != "none" || "$POD_CIDR" != "$CILIUM_POD_CIDR" ]]; then
        printf 'error: AKS must report networkPlugin=none and podCidr=%s before Flex provisioning; observed networkPlugin=%s podCidr=%s\n' \
          "$CILIUM_POD_CIDR" "$NETWORK_PLUGIN" "$POD_CIDR" >&2
        exit 1
      fi

      az aks get-credentials \
        --resource-group "$AKS_RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --overwrite-existing \
        --only-show-errors >/dev/null
      kubelogin convert-kubeconfig -l azurecli >/dev/null

      helm repo add cilium https://helm.cilium.io/ --force-update >/dev/null
      helm repo update cilium >/dev/null

      CILIUM_RELEASE_STATUS="$(helm status cilium --namespace kube-system -o json 2>/dev/null | jq -r '.info.status // empty' || true)"
      if [[ "$CILIUM_RELEASE_STATUS" == pending-* ]]; then
        LAST_DEPLOYED_REVISION="$(helm history cilium --namespace kube-system -o json | jq -r '[.[] | select(.status == "deployed")] | last | .revision // empty')"
        if [[ -z "$LAST_DEPLOYED_REVISION" ]]; then
          printf 'error: Cilium release is %s but has no deployed revision to restore\n' "$CILIUM_RELEASE_STATUS" >&2
          exit 1
        fi
        helm rollback cilium "$LAST_DEPLOYED_REVISION" \
          --namespace kube-system \
          --wait \
          --timeout 10m
      fi

      helm upgrade --install cilium cilium/cilium \
        --namespace kube-system \
        --set ipam.mode=cluster-pool \
        --set "ipam.operator.clusterPoolIPv4PodCIDRList={$${CILIUM_POD_CIDR}}" \
        --set ipam.operator.clusterPoolIPv4MaskSize=24 \
        --set routingMode=tunnel \
        --set tunnelProtocol=vxlan \
        --set kubeProxyReplacement=true

      kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
      kubectl -n kube-system rollout status daemonset/cilium-envoy --timeout=10m
    EOT
  }

  depends_on = [module.aks]
}

resource "azapi_update_resource" "managed_istio_gateway_api" {
  type        = local.managed_istio_gateway_api_managed_cluster_api_type
  resource_id = module.aks.cluster_id

  body = {
    properties = {
      ingressProfile = {
        gatewayAPI = {
          installation = "Standard"
        }
        webAppRouting = {
          enabled = true
          gatewayAPIImplementations = {
            appRoutingIstio = {
              mode = "Enabled"
            }
          }
        }
      }
    }
  }

  timeouts {
    create = "1h"
    update = "1h"
  }

  depends_on = [terraform_data.cilium]
}

resource "terraform_data" "managed_istio_ready" {
  triggers_replace = [azapi_update_resource.managed_istio_gateway_api.id]

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]

    environment = {
      AKS_CLUSTER_NAME   = module.aks.cluster_name
      AKS_RESOURCE_GROUP = azurerm_resource_group.this.name
    }

    command = <<-EOT
      set -euo pipefail

      az aks get-credentials \
        --resource-group "$AKS_RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --overwrite-existing \
        --only-show-errors >/dev/null
      kubelogin convert-kubeconfig -l azurecli >/dev/null

      CONSECUTIVE_SUCCESSES=0
      for ATTEMPT in $(seq 1 120); do
        CLASS_ACCEPTED="$(kubectl get gatewayclass approuting-istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' --request-timeout=10s 2>/dev/null || true)"
        if [[ "$CLASS_ACCEPTED" == "True" ]] && kubectl get --raw=/readyz --request-timeout=10s >/dev/null 2>&1; then
          CONSECUTIVE_SUCCESSES=$((CONSECUTIVE_SUCCESSES + 1))
          if [[ "$CONSECUTIVE_SUCCESSES" -ge 5 ]]; then
            printf 'AKS App Routing Istio is ready and authenticated API access is stable.\n'
            exit 0
          fi
        else
          CONSECUTIVE_SUCCESSES=0
        fi
        sleep 5
      done

      kubectl get gatewayclass -o wide || true
      printf 'error: AKS App Routing Istio did not become ready with stable API access within 10 minutes\n' >&2
      exit 1
    EOT
  }

  depends_on = [azapi_update_resource.managed_istio_gateway_api]
}
