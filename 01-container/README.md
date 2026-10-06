# 01 · The spam filter in a container

The blogging platform checks each new comment with a spam filter service. This folder has
that service (a [FastAPI](https://fastapi.tiangolo.com) app with a small pretrained model from
Hugging Face) and its `Dockerfile`. All other projects in this repository use this image.

**Problem.** A service that runs on the laptop of a developer often fails on a server: a
dependency is missing, a library has a different version, the model is downloaded at start
and the server has no access, or the server runs a different Python. Each server that is set
up by hand is a bit different.

**Idea.** Put the service, all its dependencies, and the model into one container image.
Build the image once and run the same image on the laptop, in CI, and in production. Pin each
version (base image, Python packages, model), keep build tools out of the image, and let the
image report its own health.

The `Dockerfile` has two stages. The first stage downloads the model at a fixed revision and
converts it to [ONNX](https://onnx.ai); this needs PyTorch. The second stage copies only the
converted model and the runtime dependencies from the lockfile:

```dockerfile
FROM python:3.13-slim@sha256:bf44cdfc... AS base
COPY --from=astral/uv:0.11.33 /uv /usr/local/bin/uv

FROM base AS model
RUN uv sync --locked --only-group export
RUN uv run --no-sync python export_model.py /model

FROM base AS runtime
RUN uv sync --locked
COPY --from=model /model /app/model
USER app
HEALTHCHECK CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
```

The service reads its configuration from environment variables, so that one image can run
with different settings (`spamfilter/app.py`):

```python
THRESHOLD = float(os.environ.get("SPAM_THRESHOLD", "0.5"))
API_KEY = os.environ.get("API_KEY")
APP_VERSION = os.environ.get("APP_VERSION", "dev")
```

## What the code shows

`demo.sh` (output in [`transcript.txt`](transcript.txt)):

1. **Two stages.** The build stage with PyTorch is about 3.1 GB, the service image about
   0.8 GB (sizes as Docker reports them). PyTorch is not in the service image.
2. **Health.** Docker runs the health check and reports the container as `healthy`. The
   service runs as the user `app`, not as `root`.
3. **Spam check.** 200 synthetic comments in about 1 s; 190 of 200 decisions are correct. Some
   friendly comments ("Thanks for writing about ... Could you share more details?") are
   flagged as spam: the pretrained model is not perfect.
4. **Configuration.** The same image with `SPAM_THRESHOLD=0.99` lets such a comment
   (score 0.981) through.
5. **No network.** The image starts with `--network none`: the model is in the image.
6. **Rollback.** Release 1.1 replaces 1.0; the rollback starts the old tag again. Each tag
   points to a fixed image ID.

Endpoints: `POST /check` (`{"text": ...}` → `{"spam": ..., "score": ...}`), `GET /health`,
`GET /metrics` (Prometheus metrics, see [05](../05-monitoring/)). Each check writes one JSON
log line.

## Tools

- [Docker](https://docs.docker.com): builds and runs containers. Here: the image of the spam
  filter, with a multi-stage build and a health check.
- [uv](https://docs.astral.sh/uv/): a Python package and project manager. Here: installs the
  exact versions from `uv.lock` into the image.
- [FastAPI](https://fastapi.tiangolo.com) with [Uvicorn](https://www.uvicorn.org): a web
  framework and its server. Here: the HTTP API of the spam filter.
- [OTIS spam model](https://huggingface.co/Titeiiko/OTIS-Official-Spam-Model): a small (4M
  parameters) pretrained BERT model that classifies text as spam (BSD-3 license). Here: the
  model behind the spam filter; we do not train it.
- [Transformers](https://huggingface.co/docs/transformers) and
  [PyTorch](https://pytorch.org): load and run pretrained models. Here: only in the build
  stage, to convert the model to ONNX.
- [ONNX Runtime](https://onnxruntime.ai) and
  [tokenizers](https://huggingface.co/docs/tokenizers): a fast inference engine and a fast
  tokenizer. Here: run the converted model in the service, without PyTorch.
- [Prometheus Python client](https://prometheus.github.io/client_python/): exports metrics.
  Here: the `/metrics` endpoint.

## Run

With [Docker](https://docs.docker.com/get-docker/) and [uv](https://docs.astral.sh/uv/):

```sh
./demo.sh                                        # build, run, check, roll back
docker run -p 8000:8000 spamfilter:1.0           # only run the service
uv run ../traffic/send_traffic.py -n 100         # send comments to localhost:8000
```

Without Docker: `uv run --group export python export_model.py` and then
`uv run uvicorn spamfilter.app:app`.
