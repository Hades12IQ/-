# Firas AI — Local Knowledge Base

Bundled, expandable reference corpus that **silently grounds** answers (RAG). Only
genuinely relevant passages are injected as hidden context, so accuracy improves
without hurting latency (retrieval is lexical + cached in memory).

## Structure

```
knowledge/
  <subject>/<topic>.json     ← source you edit (math/ science/ arabic/ quran/ …)
  build.mjs                  ← compiler
  compiled.mjs               ← generated · imported by server.mjs AND the edge function
  compiled.json              ← generated · same data, for tooling
  index.json                 ← generated · manifest (subjects → topics → counts)
```

## Add knowledge (scales to thousands of files)

1. Create a JSON file in a subject folder, e.g. `knowledge/math/vectors.json`:

   ```json
   {
     "subject": "math",
     "topic": "vectors",
     "title": "المتجهات — Vectors",
     "entries": [
       { "q": "جمع المتجهات", "k": ["متجه", "vector"], "a": "..." }
     ]
   }
   ```

   - `q` — the heading / question (indexed for retrieval)
   - `k` — keywords that should surface this entry
   - `a` — the fact/answer. Keep it to ~one idea (< 700 chars) so it stays one chunk.

   To add a whole new subject, make a new folder and add its name to `SUBJECT_DIRS`
   in `build.mjs`.

2. Compile:

   ```
   node knowledge/build.mjs
   ```

3. Restart the server (or redeploy). No code change needed — the corpus is live.

## Notes

- Content must be **accurate**: this base exists to *reduce* hallucination.
- The injection is uncited by design (the model answers as its own knowledge).
- `compiled.*` and `index.json` are generated — never edit them by hand.
