variable "kubeconfig_path" {
  description = "Path to the kubeconfig produced by 01-cluster"
  type        = string
  default     = "../01-cluster/outputs/kubeconfig.yaml"
}

variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

variable "argocd_release_name" {
  type    = string
  default = "argocd"
}

variable "argocd_chart_version" {
  description = "Version of the argo/argo-cd Helm chart (pin explicitly for reproducibility)"
  type        = string
  default     = "7.6.12"
}
