"""Download the pretrained spam classifier at a pinned revision and convert it to ONNX."""

import sys
from pathlib import Path

import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

REPO = "Titeiiko/OTIS-Official-Spam-Model"
REVISION = "2586e3df31d9ba3643392b1d761e733eb1055e4d"

out = Path(sys.argv[1] if len(sys.argv) > 1 else "model")
out.mkdir(parents=True, exist_ok=True)
model = AutoModelForSequenceClassification.from_pretrained(REPO, revision=REVISION).eval()
tokenizer = AutoTokenizer.from_pretrained(REPO, revision=REVISION)

example = tokenizer(["an example comment"], return_tensors="pt")
batch, seq = torch.export.Dim("batch"), torch.export.Dim("seq", max=512)
torch.onnx.export(
    model,
    (example["input_ids"], example["attention_mask"]),
    out / "model.onnx",
    input_names=["input_ids", "attention_mask"],
    output_names=["logits"],
    dynamic_shapes=({0: batch, 1: seq}, {0: batch, 1: seq}),
    external_data=False,
)
tokenizer.backend_tokenizer.save(str(out / "tokenizer.json"))
(out / "VERSION").write_text(f"{REPO}@{REVISION[:7]}\n")
print(f"exported {REPO}@{REVISION[:7]} to {out}/")
