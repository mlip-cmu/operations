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

1. minikube starts a cluster with one node. The three pods are ready within a few seconds,
   behind one service with a fixed address.
2. **Self-healing.** A pod is deleted; Kubernetes starts a new one at once, and it is ready
   about 4 s later.
3. **Rolling update** to version 1.1: Kubernetes replaces the pods one at a time. Then all
   answers come from version 1.1, from different pods.
4. **Bad update** (a wrong model path): the new pod crashes and restarts (3 restarts in 45 s)
   and never becomes ready. Because of `maxUnavailable: 0`, the three old pods keep running:
   the update stops, and users still get answers from version 1.1. The log of the new pod
   shows the cause (`NO_SUCHFILE`). `kubectl rollout undo` goes back to version 1.1.
5. **Autoscaling.** Under load from 32 parallel clients, the CPU use goes to about 120% of the
   request. The autoscaler increases the number of pods from 3 to 6 and then to 8, but only 4
   pods run: the other 4 stay `Pending`, because the single node has no free CPU for them.
   More pods help only when the cluster has capacity; in a cloud, a cluster autoscaler adds
   nodes. All 43,779 comments of the 3 minutes get an answer (median 108 ms).

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
