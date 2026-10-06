"""Worker: takes comments from the queue and asks the spam filter about each one."""

import json
import os
import time

import httpx
import redis

db = redis.Redis.from_url(
    os.environ.get("REDIS_URL", "redis://localhost:6379"), decode_responses=True
)
FILTER_URL = os.environ.get("SPAMFILTER_URL", "http://localhost:8000")
QUEUE, PROCESSING = "queue:spamcheck", "queue:processing"


def log(**fields):
    print(json.dumps(fields), flush=True)


def main():
    log(event="started", filter=FILTER_URL)
    while True:
        cid = db.blmove(QUEUE, PROCESSING, timeout=1, src="RIGHT", dest="LEFT")
        if cid is None:
            continue
        text = db.hget(f"comment:{cid}", "text")
        try:
            r = httpx.post(f"{FILTER_URL}/check", json={"text": text}, timeout=2)
            r.raise_for_status()
        except httpx.HTTPError as e:
            # the spam filter is not available: put the comment back and try again later
            db.lmove(PROCESSING, QUEUE, src="LEFT", dest="RIGHT")
            log(event="filter_unavailable", comment=cid, error=type(e).__name__)
            time.sleep(2)
            continue
        status = "spam" if r.json()["spam"] else "published"
        db.hset(f"comment:{cid}", "status", status)
        db.hincrby("stats", status)
        db.lrem(PROCESSING, 1, cid)
        log(event="filtered", comment=cid, status=status)


if __name__ == "__main__":
    main()
