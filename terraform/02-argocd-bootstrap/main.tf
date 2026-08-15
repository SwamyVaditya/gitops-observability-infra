provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.argocd_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "argocd" {
  name             = var.argocd_release_name
  namespace        = kubernetes_namespace.argocd.metadata[0].name
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  create_namespace = false
  wait             = true
  timeout          = 600

  # server.insecure: local lab only. We terminate TLS at the Traefik ingress
  # (Step 4) instead of doing double-TLS through Argo CD's own cert.
  # Ingress itself is NOT created here — it's managed declaratively in the
  # separate gitops-observability-config repo, under apps/infra/.
  values = [
    yamlencode({
      configs = {
        params = {
          "server.insecure" = true
        }
      }
      server = {
        ingress = {
          enabled = false
        }
      }
    })
  ]
}
