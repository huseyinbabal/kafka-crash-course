terraform {
  required_version = ">= 1.4.0"
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = ">= 2.68.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.38.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.4"
    }
  }
}

provider "digitalocean" {
  # Reads DIGITALOCEAN_TOKEN from env
}

provider "helm" {
  kubernetes = {
    host  = digitalocean_kubernetes_cluster.this.endpoint
    token = digitalocean_kubernetes_cluster.this.kube_config[0].token
    cluster_ca_certificate = base64decode(
      digitalocean_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate
    )
  }
}

provider "kubernetes" {
  host  = digitalocean_kubernetes_cluster.this.endpoint
  token = digitalocean_kubernetes_cluster.this.kube_config[0].token
  cluster_ca_certificate = base64decode(
    digitalocean_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate
  )
}

# -------- Variables (override with -var or tfvars) --------
variable "region" {
  type    = string
  default = "fra1"
}

variable "cluster_name" {
  type    = string
  default = "kafka-load"
}

# Use a valid DO Kubernetes version slug; update as needed.
# You can list with: doctl kubernetes options versions
variable "k8s_version" {
  type    = string
  default = "1.34.1-do.0"
}

variable "controllers_count" {
  type    = number
  default = 3
}

variable "brokers_count" {
  type    = number
  default = 5
}

variable "clients_count" {
  type    = number
  default = 14
}

variable "monitor_count" {
  type    = number
  default = 1
}

# -------- Optional: VPC for cluster isolation --------
resource "digitalocean_vpc" "kafka_vpc" {
  name     = "${var.cluster_name}-vpc"
  region   = var.region
  ip_range = "10.20.0.0/16"
}

# -------- Cluster (default pool = controller-pool) --------
resource "digitalocean_kubernetes_cluster" "this" {
  name          = var.cluster_name
  region        = var.region
  version       = var.k8s_version
  vpc_uuid      = digitalocean_vpc.kafka_vpc.id
  auto_upgrade  = true
  surge_upgrade = true
  tags          = ["env:loadtest", "app:kafka", var.cluster_name]

  # Default node pool must live in the cluster resource
  node_pool {
    name       = "controller-pool"
    size       = "s-2vcpu-4gb"
    node_count = var.controllers_count

    labels = {
      "doks.digitalocean.com/node-pool" = "controller-pool"
      "role"                            = "controller"
    }

    # If you want to hard-protect controllers:
    # taint {
    #   key    = "role"
    #   value  = "controller"
    #   effect = "NoSchedule"
    # }
  }
}

# -------- Additional pools --------

# Kafka brokers
resource "digitalocean_kubernetes_node_pool" "broker_pool" {
  cluster_id = digitalocean_kubernetes_cluster.this.id
  name       = "kafka-broker-pool"
  size       = "c-8" # 8 vCPU / 16GB (CPU-Optimized)
  node_count = var.brokers_count

  labels = {
    "doks.digitalocean.com/node-pool" = "kafka-broker-pool"
    "role"                            = "broker"
  }

  tags = ["role:broker", var.cluster_name]
}

# Client pool (producers/consumers)
resource "digitalocean_kubernetes_node_pool" "client_pool" {
  cluster_id = digitalocean_kubernetes_cluster.this.id
  name       = "client-pool"
  size       = "s-8vcpu-16gb"
  node_count = var.clients_count

  labels = {
    "doks.digitalocean.com/node-pool" = "client-pool"
    "role"                            = "client"
  }

  tags = ["role:client", var.cluster_name]

  # Optional: tolerate only client workloads (match a taint you add manually to nodes)
  # taint {
  #   key    = "client-pool"
  #   value  = "true"
  #   effect = "NoSchedule"
  # }
}

# Monitoring pool (Prometheus/Grafana)
resource "digitalocean_kubernetes_node_pool" "monitor_pool" {
  cluster_id = digitalocean_kubernetes_cluster.this.id
  name       = "monitoring-pool"
  size       = "s-4vcpu-8gb"
  node_count = var.monitor_count

  labels = {
    "doks.digitalocean.com/node-pool" = "monitoring-pool"
    "role"                            = "monitoring"
  }

  tags = ["role:monitoring", var.cluster_name]
}

# -------- Helm Releases --------

# Deploy kube-prometheus-stack for monitoring
resource "helm_release" "kube_prometheus_stack" {
  name             = "monitoring"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  version          = "79.0.0" # Update as needed

  values = [
    file("${path.module}/monitoring-values.yaml")
  ]

  # Ensure cluster and monitoring pool are ready before deploying
  depends_on = [
    digitalocean_kubernetes_cluster.this,
    digitalocean_kubernetes_node_pool.monitor_pool
  ]

  # Timeout for installation (in seconds)
  timeout = 600

  # Wait for all resources to be ready
  wait = true

  dependency_update = true
}

# Deploy Strimzi Kafka Operator
resource "helm_release" "strimzi_kafka_operator" {
  name             = "strimzi-kafka-operator"
  repository       = "oci://quay.io/strimzi-helm"
  chart            = "strimzi-kafka-operator"
  namespace        = "kafka-system"
  create_namespace = true

  # Ensure cluster is ready before deploying
  depends_on = [
    digitalocean_kubernetes_cluster.this
  ]

  # Timeout for installation (in seconds)
  timeout = 600

  # Wait for all resources to be ready
  wait = true

  set = [
    {
      name  = "watchNamespaces[0]"
      value = "kafka"
    }
  ]
}

# -------- Kubernetes Resources --------

# ConfigMap for Grafana Kafka Dashboard
resource "kubernetes_config_map" "grafana_kafka_dashboard" {
  metadata {
    name      = "grafana-kafka-dashboard"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "kafka-dashboard.json" = replace(
      file("${path.module}/grafana-kafka-dashboard.json"),
      "$${DS_PROMETHEUS}",
      "Prometheus"
    )
  }

  depends_on = [
    helm_release.kube_prometheus_stack
  ]
}

# Kafka namespace
resource "kubernetes_namespace" "kafka" {
  metadata {
    name = "kafka"
  }

  depends_on = [
    digitalocean_kubernetes_cluster.this
  ]
}

# Apply Kafka manifests using kubectl
resource "null_resource" "apply_kafka_manifests" {
  triggers = {
    kafka_yaml_sha = filesha256("${path.module}/kafka.yaml")
    cluster_id     = digitalocean_kubernetes_cluster.this.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Write kubeconfig to temporary file
      echo '${digitalocean_kubernetes_cluster.this.kube_config[0].raw_config}' > /tmp/kubeconfig-${digitalocean_kubernetes_cluster.this.id}

      # Apply the kafka manifests
      kubectl --kubeconfig=/tmp/kubeconfig-${digitalocean_kubernetes_cluster.this.id} apply -f ${path.module}/kafka.yaml

      # Clean up
      rm -f /tmp/kubeconfig-${digitalocean_kubernetes_cluster.this.id}
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      # Note: This will only work if the cluster still exists
      echo "Kafka resources will be deleted with the cluster"
    EOT
  }

  depends_on = [
    kubernetes_namespace.kafka,
    digitalocean_kubernetes_node_pool.broker_pool,
    helm_release.strimzi_kafka_operator
  ]
}

# -------- Outputs --------
output "cluster_id" {
  value = digitalocean_kubernetes_cluster.this.id
}

output "kubeconfig" {
  description = "Raw kubeconfig for the cluster"
  value       = digitalocean_kubernetes_cluster.this.kube_config[0].raw_config
  sensitive   = true
}

output "api_server_endpoint" {
  value = digitalocean_kubernetes_cluster.this.endpoint
}

output "broker_pool_nodes" {
  value = digitalocean_kubernetes_node_pool.broker_pool.nodes[*].id
}

