variable "cluster_name" {
  description = "Name of the k3d cluster (also the k3s/kubectl context name)"
  type        = string
  default     = "gitops-observability-lab"
}

variable "k3s_version" {
  description = "k3s image tag used for all nodes"
  type        = string
  default     = "v1.29.4-k3s1"
}

variable "server_count" {
  description = "Number of k3s server (control-plane) nodes"
  type        = number
  default     = 1
}

variable "agent_count" {
  description = "Number of k3s agent (worker) nodes"
  type        = number
  default     = 2
}

variable "http_host_port" {
  description = "Host port mapped to the k3d load balancer for HTTP traffic (Traefik)"
  type        = number
  default     = 80
}

variable "https_host_port" {
  description = "Host port mapped to the k3d load balancer for HTTPS traffic (Traefik)"
  type        = number
  default     = 443
}

variable "api_host_port" {
  description = "Host port mapped to the k3s API server, for kubectl access from outside Docker"
  type        = number
  default     = 6550
}

variable "kubeconfig_output_path" {
  description = "Path (relative to this module) where this cluster's standalone kubeconfig is written"
  type        = string
  default     = "./outputs/kubeconfig.yaml"
}
