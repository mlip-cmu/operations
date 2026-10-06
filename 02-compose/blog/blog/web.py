"""Blog web app: accepts comments and queues them for the spam check."""

import os

import redis
from fastapi import FastAPI
from prometheus_client import Counter, Gauge, make_asgi_app
from pydantic import BaseModel

db = redis.Redis.from_url(
    os.environ.get("REDIS_URL", "redis://localhost:6379"), decode_responses=True
)
QUEUE = "queue:spamcheck"

POSTED = Counter("blog_comments_posted_total", "Comments posted by readers")
WAITING = Gauge("blog_comments_waiting", "Comments waiting for the spam check")
WAITING.set_function(lambda: db.llen(QUEUE))

app = FastAPI()
app.mount("/metrics", make_asgi_app())


class NewComment(BaseModel):
    author: str
    text: str


@app.post("/posts/{post_id}/comments", status_code=201)
def add_comment(post_id: int, comment: NewComment):
    cid = db.incr("comment:next_id")
    db.hset(
        f"comment:{cid}", mapping={"post": post_id, **comment.model_dump(), "status": "pending"}
    )
    db.rpush(f"post:{post_id}:comments", cid)
    db.lpush(QUEUE, cid)  # the spam check happens later, in the worker
    POSTED.inc()
    return {"id": cid, "status": "pending"}


@app.get("/posts/{post_id}/comments")
def published_comments(post_id: int):
    ids = db.lrange(f"post:{post_id}:comments", 0, -1)
    comments = [db.hgetall(f"comment:{cid}") for cid in ids]
    return [c for c in comments if c["status"] == "published"]


@app.get("/stats")
def stats():
    counts = db.hgetall("stats")
    return {
        "waiting": db.llen(QUEUE),
        "published": int(counts.get("published", 0)),
        "spam": int(counts.get("spam", 0)),
    }


@app.get("/health")
def health():
    db.ping()
    return {"status": "ok"}
