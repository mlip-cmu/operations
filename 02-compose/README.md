# 02 · The blog system with Docker Compose

The blogging platform has several parts: a web app where readers post comments, a queue, a
worker that sends each new comment to the spam filter, and the spam filter itself (the image
from [01](../01-container/)). This project runs all parts together on one machine.

**Problem.** A system with several services is hard to start by hand: each service needs its
own configuration, the services must find each other on the network, and some must start
before others. If the blog calls the spam filter directly, a failure of the spam filter also
breaks the blog.

**Idea.** Describe all services, their configuration, network, storage, and health checks in
one file, and start everything with one command. Put a queue between the blog and the spam
filter, so that the blog keeps working when the spam filter is down: new comments wait in the
queue, and the worker checks them when the spam filter is back.

`compose.yaml` declares the services (shortened here); the names (`redis`, `spamfilter`) are
also their host names on the network:

```yaml
services:
  blog:
    build: ./blog
    ports: ["8080:8000"]
    environment:
      REDIS_URL: redis://redis:6379
    depends_on:
      redis: { condition: service_healthy }
  worker:
    build: ./blog
    command: ["python", "-m", "blog.worker"]
    environment:
      SPAMFILTER_URL: http://spamfilter:8000
  spamfilter:
    build: ../01-container
  redis:
    image: redis:8.8.3-alpine
```

The blog only puts the new comment into the queue (`blog/blog/web.py`); the worker
(`blog/blog/worker.py`) puts a comment back into the queue when the spam filter does not
answer:

```python
try:
    r = httpx.post(f"{FILTER_URL}/check", json={"text": text}, timeout=2)
    r.raise_for_status()
except httpx.HTTPError as e:
    db.lmove(PROCESSING, QUEUE, src="LEFT", dest="RIGHT")
    log(event="filter_unavailable", comment=cid, error=type(e).__name__)
    time.sleep(2)
    continue
```

## What the code shows

`demo.sh` (output in [`transcript.txt`](transcript.txt)):

1. `docker compose up --wait` builds the images, starts four services in the correct order,
   and waits until they are healthy.
2. 30 comments: the worker checks all of them within about 1 s (20 published, 10 spam).
3. The spam filter is stopped. The blog still accepts all 30 new comments (median about
   10 ms); they wait in the queue (`"waiting": 30`), and the worker logs
   `filter_unavailable`. A direct call to the spam filter fails.
4. The spam filter starts again; the worker checks the 30 waiting comments within about 3 s.

The system level and the component level are different: the spam filter was down, but the
blog stayed available. The price is a delay: a comment shows only after its spam check.

## Tools

- [Docker Compose](https://docs.docker.com/compose/): runs a system of several containers
  from one YAML file. Here: the blog, the worker, the spam filter, and Redis.
- [Redis](https://redis.io): an in-memory data store. Here: stores the comments and is the
  queue between the blog and the worker (`LPUSH`, `BLMOVE`).
- [FastAPI](https://fastapi.tiangolo.com): a Python web framework. Here: the blog web app.
- [HTTPX](https://www.python-httpx.org): an HTTP client for Python. Here: the worker calls
  the spam filter, and `../traffic/send_traffic.py` posts comments.

## Run

With [Docker](https://docs.docker.com/get-docker/) and [uv](https://docs.astral.sh/uv/):

```sh
./demo.sh                     # start, stop the spam filter, start it again
docker compose up -d --build  # only start the system; the blog is at http://localhost:8080
uv run ../traffic/send_traffic.py --target blog --url http://localhost:8080
curl localhost:8080/stats
docker compose down -v        # stop and remove everything
```
