# 04 · The spam filter on Kubernetes

The spam filter of the blogging platform (the image from [01](../01-container/)) must stay
available when a server fails, must handle more comments when a post goes viral, and must get
updates without downtime. This project runs it on a local Kubernetes cluster
([minikube](https://minikube.sigs.k8s.io)).

**Problem.** With containers alone, an operator still decides by hand how many copies of each
service run, on which machine, and what happens when one crashes or the load grows. Updates
replace containers one by one, and a bad update can take the service down.

**Idea.** Declare the wanted state (three copies of this image, with these resources and
health checks), and let an orchestrator keep the actual state equal to it: it restarts or
replaces failed copies, balances requests over them, replaces them one at a time in an
update, stops an update whose new copies are not healthy, and adds copies under load.

The deployment declares three copies (pods) of the image and how to check their health
(`k8s/deployment.yaml`, shortened):

```yaml
spec:
  replicas: 3
  strategy:
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    spec:
      containers:
        - name: spamfilter
          image: spamfilter:1.0
          resources:
            requests: { cpu: 250m, memory: 128Mi }
            limits: { cpu: 500m, memory: 256Mi }
          readinessProbe:
            httpGet: { path: /health, port: 8000 }
```

The autoscaler adds pods when the average CPU use is above 50% of the request
(`k8s/autoscaler.yaml`):

```yaml
spec:
  minReplicas: 3
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 50 }
```

## What the code shows

`demo.sh` (output in [`transcript.txt`](transcript.txt), recorded in GitHub Actions):

RESULTS

## Tools

- [Kubernetes](https://kubernetes.io): a container orchestrator. Here: the deployment, the
  service, and the autoscaler for the spam filter.
- [minikube](https://minikube.sigs.k8s.io): a local Kubernetes cluster in a container. Here:
  the cluster for the demo; `minikube image load` copies the local images into it.
- [kubectl](https://kubernetes.io/docs/reference/kubectl/): the command-line client of
  Kubernetes. Here: apply the manifests, watch the pods, update and roll back.
- [metrics-server](https://github.com/kubernetes-sigs/metrics-server): collects the CPU and
  memory use of the pods. Here: the input of the autoscaler.

## Run

With [Docker](https://docs.docker.com/get-docker/), [uv](https://docs.astral.sh/uv/),
[minikube](https://minikube.sigs.k8s.io/docs/start/), and
[kubectl](https://kubernetes.io/docs/tasks/tools/):

```sh
./demo.sh                    # starts minikube if necessary; takes about 10 minutes
kubectl get pods --watch     # in a second terminal: see the pods change
minikube stop                # stop the cluster
```

The demo reaches the service through the node port of the cluster (`minikube ip`). This works
on Linux. With Docker Desktop (macOS, Windows) the cluster node is not reachable from the host;
run the demo in a Linux machine or in a GitHub Codespace, or open the service with
`minikube service spamfilter`.
