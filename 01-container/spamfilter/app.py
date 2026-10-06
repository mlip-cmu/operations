"""Spam filter service: decides whether a blog comment is spam."""

import json
import logging
import os
import time
from contextlib import asynccontextmanager
from pathlib import Path

import numpy as np
import onnxruntime as ort
from fastapi import FastAPI, Header, HTTPException
from prometheus_client import Counter, Histogram, make_asgi_app
from pydantic import BaseModel
from tokenizers import Tokenizer

MODEL_DIR = Path(os.environ.get("MODEL_DIR", "model"))
THRESHOLD = float(os.environ.get("SPAM_THRESHOLD", "0.5"))
API_KEY = os.environ.get("API_KEY")
APP_VERSION = os.environ.get("APP_VERSION", "dev")

CHECKED = Counter("spamfilter_comments_total", "Checked comments", ["result"])
LATENCY = Histogram(
    "spamfilter_inference_seconds",
    "Model inference time",
    buckets=[0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1],
)

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("spamfilter")


class SpamModel:
    def __init__(self, model_dir: Path):
        self.session = ort.InferenceSession(model_dir / "model.onnx")
        self.tokenizer = Tokenizer.from_file(str(model_dir / "tokenizer.json"))
        self.tokenizer.enable_truncation(256)
        self.version = (model_dir / "VERSION").read_text().strip()

    def spam_probability(self, text: str) -> float:
        enc = self.tokenizer.encode(text)
        logits = self.session.run(
            None,
            {
                "input_ids": np.array([enc.ids], dtype=np.int64),
                "attention_mask": np.array([enc.attention_mask], dtype=np.int64),
            },
        )[0][0]
        p = np.exp(logits - logits.max())
        return float(p[1] / p.sum())


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.model = SpamModel(MODEL_DIR)
    log.info(
        json.dumps({"event": "started", "version": APP_VERSION, "model": app.state.model.version})
    )
    yield


app = FastAPI(lifespan=lifespan)
app.mount("/metrics", make_asgi_app())


class Comment(BaseModel):
    text: str


@app.get("/health")
def health():
    return {"status": "ok", "version": APP_VERSION, "model": app.state.model.version}


@app.post("/check")
def check(comment: Comment, x_api_key: str | None = Header(default=None)):
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="invalid API key")
    start = time.perf_counter()
    score = app.state.model.spam_probability(comment.text)
    elapsed = time.perf_counter() - start
    spam = score >= THRESHOLD
    LATENCY.observe(elapsed)
    CHECKED.labels(result="spam" if spam else "ham").inc()
    log.info(
        json.dumps(
            {
                "event": "checked",
                "spam": spam,
                "score": round(score, 3),
                "ms": round(elapsed * 1000, 1),
                "chars": len(comment.text),
            }
        )
    )
    return {"spam": spam, "score": round(score, 3), "version": APP_VERSION}
