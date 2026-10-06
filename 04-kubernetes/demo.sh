#!/usr/bin/env bash
# Run the spam filter on a local Kubernetes cluster (minikube): deploy, self-healing,
# rolling update, a bad update with rollback, and autoscaling.
# The output also goes to transcript.txt.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
exec > >(tee transcript.txt) 2>&1

step() { printf '\n== %s\n' "$*"; }
show() {
  printf '$'
  for a in "$@"; do [[ $a =~ [[:space:]\;\{] ]] && printf " '%s'" "$a" || printf ' %s' "$a"; done
  echo
}
run() { show "$@"; "$@"; }
health() { for _ in $(seq "$1"); do curl -s "$URL/health"; echo; done; }

step "0. Start a local cluster and load the images"
minikube status >/dev/null 2>&1 || minikube start --driver=docker >/dev/null
minikube addons enable metrics-server >/dev/null
docker build -q -t spamfilter:1.0 --build-arg APP_VERSION=1.0 ../01-container >/dev/null
docker build -q -t spamfilter:1.1 --build-arg APP_VERSION=1.1 ../01-container >/dev/null
run minikube image load spamfilter:1.0
run minikube image load spamfilter:1.1
kubectl delete -f k8s --ignore-not-found >/dev/null
run kubectl get nodes

step "1. Deploy three pods behind one service"
run kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml
run kubectl rollout status deployment/spamfilter --timeout=180s
run kubectl get pods
URL=$(minikube service spamfilter --url)
echo "# the service balances requests over the pods (see \"host\"):"
health 4

step "2. Self-healing: a pod is deleted, Kubernetes starts a new one"
victim=$(kubectl get pods -l app=spamfilter -o jsonpath='{.items[0].metadata.name}')
run kubectl delete pod "$victim" --wait=false
sleep 2
run kubectl get pods
kubectl wait --for=condition=Ready pod -l app=spamfilter --timeout=120s >/dev/null
run kubectl get pods

step "3. Rolling update to version 1.1: one pod at a time, no downtime"
run kubectl set image deployment/spamfilter spamfilter=spamfilter:1.1
run kubectl rollout status deployment/spamfilter --timeout=180s
health 2

step "4. A bad update: the new pod cannot start; the old pods keep serving"
run kubectl set env deployment/spamfilter MODEL_DIR=/models/missing
show kubectl rollout status deployment/spamfilter --timeout=45s
kubectl rollout status deployment/spamfilter --timeout=45s || true
run kubectl get pods
newest=$(kubectl get pods -l app=spamfilter --sort-by=.metadata.creationTimestamp -o name | tail -1)
show kubectl logs "$newest" --tail=1
kubectl logs "$newest" --tail=1 || true
echo "# users do not notice; the service still answers with version 1.1:"
health 2
echo "# roll back to the previous version of the deployment:"
run kubectl rollout undo deployment/spamfilter
run kubectl rollout status deployment/spamfilter --timeout=180s
run kubectl rollout history deployment/spamfilter
run kubectl get pods

step "5. Autoscaling: under load, Kubernetes adds pods"
run kubectl apply -f k8s/autoscaler.yaml
until kubectl get hpa spamfilter -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' | grep -q .; do
  sleep 5
done
run kubectl get hpa spamfilter
echo "# 3 minutes of load from 32 parallel clients:"
uv run --quiet ../traffic/send_traffic.py --url "$URL" --duration 180 --concurrency 32 > out/load.txt &
load=$!
printf '%-6s %-12s %s\n' "time" "cpu/target" "pods"
for t in $(seq 20 20 200); do
  sleep 20
  printf '%-6s %-12s %s\n' "${t}s" \
    "$(kubectl get hpa spamfilter -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}')%/50%" \
    "$(kubectl get hpa spamfilter -o jsonpath='{.status.currentReplicas}')"
done
wait $load
cat out/load.txt
run kubectl get pods

step "6. Clean up (the cluster keeps running; stop it with: minikube stop)"
run kubectl delete -f k8s
