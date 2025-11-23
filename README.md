# Kafka Crash Course Setup Guide

## 1. Infrastructure Setup

First, export your DigitalOcean API key and provision the infrastructure.

```bash
export DIGITALOCEAN_API_KEY=your_api_key_here

cd iac/
terraform init
terraform plan
terraform apply -auto-approve
```

## 2. Verify Installation

Check if the cluster, monitoring stack, and Kafka cluster are running correctly.

```bash
kubectl get pods --all-namespaces
```

## 3. Deploy Producers and Consumers

Navigate back to the root directory and deploy the producer and consumer.

```bash
cd ..
kubectl apply -f producer.yaml
kubectl apply -f consumer.yaml
```

## 4. Access Monitoring Dashboard

Port-forward the Grafana service to access the dashboards.

```bash
# Replace 'grafana-pod-name' with the actual pod name from your monitoring namespace
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:3000 -n monitoring
```

Open [http://localhost:3000](http://localhost:3000) in your browser.
Default credentials usually are `admin` / <pass> (check `monitoring-grafana` secret).

Navigate to the **Strimzi Kafka** dashboard to monitor your cluster.
