import polars as pl, json, urllib.request, time
t0=time.time()
terms = pl.read_csv('/tmp/terms_2col.tsv', separator='\t', has_header=False, new_columns=['hash','text'])
texts = terms['text'].to_list(); hashes = terms['hash'].to_list()
def embed_batch(b):
    req = urllib.request.Request('http://localhost:11434/v1/embeddings',
        data=json.dumps({'model':'bge-m3','input':b}).encode(),
        headers={'Content-Type':'application/json'})
    return [x['embedding'] for x in json.loads(urllib.request.urlopen(req, timeout=180).read())['data']]
embs=[]; B=64
for i in range(0,len(texts),B):
    embs.extend(embed_batch(texts[i:i+B]))
    if i % 640 == 0: print(f'  {i}/{len(texts)}  ({time.time()-t0:.0f}s)', flush=True)
pl.DataFrame({'hash':hashes,'text_to_embed':texts,'embedding':embs}).write_parquet('/tmp/ols_emb_bgem3.parquet')
print(f'DONE {len(embs)} embeddings, dim {len(embs[0])}, {time.time()-t0:.0f}s -> /tmp/ols_emb_bgem3.parquet')
