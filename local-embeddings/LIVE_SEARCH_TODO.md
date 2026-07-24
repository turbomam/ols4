# Live semantic search in the local OLS4 — DONE (2026-07-24)

The local OLS4 (METPO+MIxS+AIO, one stack) now does semantic search via `llm_search` using local
bge-m3 embeddings — no cloud, no CUDA. Verified: `nitrogen fixation` -> nitrogen fixation/nitrification
[metpo]; `deep learning model` -> Large Language Model/Deep Neural Network [aio]; `soil temperature` ->
soil [mixs] + temperature range [metpo] (cross-ontology). The browser search box uses it too.

## How it works
`GET /api/v2/classes/llm_search?q=<text>&model=bgem3` -> backend `EmbeddingServiceClient.embedText`
POSTs the query to a **shim** (`local-embeddings/ols_embed_shim.py`) that proxies **ollama bge-m3** and
returns raw float32; backend does pgvector cosine (`vector_cosine_ops`, HNSW) over the `embedding_bgem3`
column of `ols_embedding_nodes`.

## The three pieces (all in place)
1. **Shim** `local-embeddings/ols_embed_shim.py` (Flask): `GET /models` -> `{"models":["bgem3"]}`;
   `POST /` `{"model":"bgem3","text":[...]}` -> raw **LITTLE-endian** float32 (`<f4`; Java
   `ByteBuffer` is `LITTLE_ENDIAN` — big-endian returns empty!) + header `x-embedding-dim: 1024`.
   Proxies ollama `POST localhost:11434/v1/embeddings`. Model name is `bgem3` (no hyphen; the backend's
   column-name sanitizer rejects hyphens).
2. **Vectors in postgres** (4,546 label vectors): columns `embedding_bgem3` on `ols_embedding_nodes`
   (type `LabelEmbedding`, `entity_id` -> `ols_entities.id`) and `embeddings_bgem3` on `ols_entities`,
   both `vector(1024)`, HNSW `vector_cosine_ops` indexed. Loaded by joining our parquet (keyed by label
   hash) to `ols_entities` by IRI.
3. **Backend config** `docker-compose.override.yml`: `OLS_EMBEDDING_SERVICE_URL=http://host.docker.internal:11435`
   on `ols4-backend` (Spring binds it to `ols.embedding.service.url`).

## Restart runbook (after a reboot or `docker compose down`)
The shim and the DB columns are ephemeral relative to a fresh reload. To bring semantic search back:
```bash
# 1. ollama must be serving bge-m3 (localhost:11434)
# 2. start the shim
( cd dataload/embeddings/ols_embed && nohup uv run python ../../../local-embeddings/ols_embed_shim.py >/tmp/ols-shim.log 2>&1 & )
# 3. if the stack is up and the DB still has the bgem3 columns, you're done (override provides the env).
#    if you re-ran reload-local-ols.sh (fresh DB), re-load the vectors:
#      - regenerate embeddings: local-embeddings/ollama_embed.py  (see local-embeddings/README.md)
#      - re-run the join + COPY + index (the ALTER/COPY/UPDATE/CREATE INDEX steps; see git history / below)
# 4. verify: curl 'http://localhost:8082/api/v2/classes/llm_search?q=nitrogen+fixation&model=bgem3'
```
Vector-load SQL (per model `bgem3`, dim 1024): `ALTER TABLE ols_entities ADD COLUMN embeddings_bgem3
vector(1024); ALTER TABLE ols_embedding_nodes ADD COLUMN embedding_bgem3 vector(1024);` then COPY
`(id,type='LabelEmbedding',entity_id,embedding_bgem3)` into `ols_embedding_nodes` (join our parquet to
`ols_entities` by IRI), UPDATE `ols_entities.embeddings_bgem3`, then two HNSW indexes
(`vector_cosine_ops`, the embedding-nodes one `WHERE type='LabelEmbedding'`). Postgres socket is `/tmp`
OR `/var/run/postgresql` (varies — detect it).

## Durability note
The shim runs via `nohup` (not a service) and depends on ollama being up; the `docker-compose.override.yml`
and the DB columns survive a plain restart but not a fresh reload. For a permanent setup, make the shim a
launchagent or a compose service, and fold the vector-load into an OLS embeddings step.
