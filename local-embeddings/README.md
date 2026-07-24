# Local OLS4: three-ontology load + on-device embeddings + cross-ontology similarity

Reproducible recipe for loading METPO + MIxS + AIO into one local OLS4 instance, generating term
embeddings on the M5 (no cloud, no CUDA), and computing cross-ontology semantic similarity. Built
2026-07-24. Informs GSC/mixs issue #1283 (retire hand-curated `keywords:`).

## 1. Load all three into one OLS4 stack
```bash
./reload-local-ols.sh dataload/configs/all-three.json
```
`all-three.json` is `{"ontologies":[metpo, mixs, aio]}` (METPO from its w3id PURL, MIxS from
`mixs_best.owl.ttl`, AIO from `aio_release.owl`). Result: one stack serving all three.
- frontend: http://localhost:8083/ontologies/{metpo,mixs,aio}
- backend:  http://localhost:8082/api/v2/ontologies
- verified counts: METPO 292, MIxS 1,360, AIO 442 classes.

The dataload runs with `enable_embeddings = false` (the stock embeddings step wants EBI's CUDA
`ols_embeddings` container / Codon SLURM cluster, which does not run locally). Embeddings are done
separately, below.

## 2. Generate embeddings locally with ollama bge-m3
Requires ollama running on the M5 with `bge-m3` pulled (reachable at http://localhost:11434; note it
binds IPv6-only via the Homebrew service, so `localhost` works but the IPv4 LAN address may not).
```bash
# extract the 2-column (hash, text) input from the load's terms.tsv (cols 6,7)
find tmp/work -name terms.tsv -exec cat {} + \
  | awk -F'\t' '$6!="hash" && $6!="" && !seen[$6]++ {print $6"\t"$7}' > /tmp/terms_2col.tsv   # ~6,127 labels
# embed via ollama bge-m3 (OpenAI-compatible /v1/embeddings), 1024-dim
( cd dataload/embeddings/ols_embed && uv sync --extra cpu && uv run python ../../../local-embeddings/ollama_embed.py )
# -> ols_emb_bgem3.parquet (hash, text_to_embed, embedding). ~54s for 6,127 terms.
```

## 3. Cross-ontology similarity
Cosine similarity between terms of different ontologies (see `cross_ontology_similarity.tsv` for a
saved run). Findings: METPO<->MIxS links trait adjectives to enum nouns (`aerobic`~`aerobe`,
`chemolithoheterotrophic`~`chemolithotroph`); MIxS<->AIO surfaces cross-domain matches, some genuine
(`taxonomic classification`~`Classification`) and some false friends (`sample pooling`~`Pooling Layer`).
Embeddings are a strong signal, not ground truth: threshold + human review, do not trust blindly.

## Files here
- `ollama_embed.py` — the embedder (reads `/tmp/terms_2col.tsv`, writes the parquet).
- `cross_ontology_similarity.tsv` — a saved cross-ontology similarity run (small).
- `ols_emb_bgem3.parquet`, `terms_*.tsv` — regenerable, gitignored (the parquet is ~46 MB).

## Why embeddings, not keywords
The MIxS `keywords:` metaslot (667 assertions, poorly maintained: `host` vs `host.` etc.) was meant
for term discovery. Embedding similarity recovers that (and more) with no per-slot curation. See
https://github.com/GenomicsStandardsConsortium/mixs/issues/1283.
