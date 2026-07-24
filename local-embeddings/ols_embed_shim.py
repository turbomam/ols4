#!/usr/bin/env python3
"""Tiny shim: speaks the OLS4 embedding-service API, proxies to ollama bge-m3.
  GET  /models  -> {"models": ["bgem3"]}
  POST /        {"model":"bgem3","text":[...]}  -> raw BIG-endian float32 (n*dim*4) + x-embedding-dim
OLS4 backend point at this via ols.embedding.service.url (OLS_EMBEDDING_SERVICE_URL)."""
import json, urllib.request
import numpy as np
from flask import Flask, request, jsonify, Response

OLLAMA = "http://localhost:11434/v1/embeddings"
MODEL_MAP = {"bgem3": "bge-m3"}
app = Flask(__name__)

@app.get("/models")
def models():
    return jsonify({"models": list(MODEL_MAP)})

@app.post("/")
def embed():
    body = request.get_json(force=True)
    texts = body["text"]
    ollama_model = MODEL_MAP.get(body["model"], body["model"])
    req = urllib.request.Request(
        OLLAMA,
        data=json.dumps({"model": ollama_model, "input": texts}).encode(),
        headers={"Content-Type": "application/json"},
    )
    d = json.loads(urllib.request.urlopen(req, timeout=300).read())
    arr = np.array([x["embedding"] for x in d["data"]], dtype="<f4")  # little-endian (Java ByteBuffer LITTLE_ENDIAN)
    return Response(
        arr.tobytes(),
        status=200,
        headers={"x-embedding-dim": str(arr.shape[1]), "Content-Type": "application/octet-stream"},
    )

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=11435)
