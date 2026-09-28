# Local Autocomplete with llama.cpp — Gemma 4 E2B

A small harness that drives a Smart-Compose-style autocomplete loop against a
local **Gemma 4 E2B** model running under `llama.cpp`, and measures **latency**
and **suggestion quality** honestly.


## Machine

- Apple **M2**, 8 cores (4P+4E), **16 GB** unified memory
- macOS 26.5, Metal GPU backend
- llama.cpp **build b9654** (prebuilt macOS arm64 release, Metal-enabled; has
  native `gemma4` architecture support)
- Models: `gemma-4-E2B` base & `-it`, both **Q4_K_M** (~3.1–3.4 GB each)

## Layout

```
bin/llama-b9654/      prebuilt llama.cpp (llama-server, llama-cli, llama-bench)
models/               *.gguf  (downloaded, not committed)
dphm.py               Dual-Path Habit Memory (hot-path suggest / cold-path learn)
fetch_corpus.py       public-data corpus: Enron single-author emails + Gutenberg
simulate_longterm.py  30-day user simulation, base vs DPHM  (THE main experiment)
visualize.py          renders results/longterm_sim.json -> results/figures/*.png
run_longterm.sh       corpus -> simulation -> figures, one command
passages.py           single test passages for the older per-passage harness
harness.py            older completion-loop harness (latency instrumentation)
harness_dphm.py       older single-passage base-vs-DPHM comparison
run_server.sh         start llama-server for a model
run_all.sh            older experiment matrix (regenerates the WRITEUP numbers)
diagnose_cache.py     reproduces the prefix-cache diagnosis (sliding-window)
data/                 downloaded corpus (raw/ cached) + user_corpus.json
results/              long-term simulation JSON, session log, figures/
WRITEUP.md            answers to the five questions
```

## The long-term memory experiment (main)

Does a personal memory layer actually pay off for a user who types every
day? `simulate_longterm.py` replays a real person's writing history from
public data as **30 daily sessions**:

- **Corpus** (`fetch_corpus.py`): all mail written by one author
  (`steven.kean@enron.com`, 250 messages, chronological, forwards/quotes
  stripped) from the public Berkeley Enron subset, interleaved with
  paragraphs of *Pride and Prejudice* (Project Gutenberg #1342) as the
  same "user's" long-form prose.
- **Protocol**: prequential (test-then-train). Each session first predicts
  the next word at ~40 cut points — `base` = llama.cpp top candidates,
  `dphm` = the *same* candidates interpolated with personal memory — then
  commits the session's texts to DPHM's cold path. A virtual clock advances
  one day per session so decay/consolidation are real.
- **Fusion**: probability-space interpolation (cache-LM / kNN-LM style),
  `P(w) = Σ_src w_src · r_src · p_src(w)`, where `r_src = n/(n+8)` shrinks
  a source that has little (decayed) evidence for the context. A source
  that hasn't seen the context contributes 0 — it never penalizes.
  Consolidated habits only get a small log-space nudge (+0.25) on top of
  their mixture score, so they win ties, not everything.
- **Observability**: every session prints accuracy (base vs dphm), memory
  size, newly promoted habits, the top recurring phrases, suggestions for
  six fixed probe prefixes, and concrete win/loss examples — the whole
  learning trajectory is in `results/longterm_sim.log`, and
  `visualize.py` turns the JSON into seven figures under `results/figures/`.

```bash
./run_longterm.sh          # everything: corpus -> 30 sessions -> figures
# or piecewise:
python3 fetch_corpus.py
./run_server.sh models/gemma-4-E2B-base-Q4_K_M.gguf 99 &
python3 simulate_longterm.py --config config.yaml --out results/longterm_sim.json
python3 visualize.py
python3 simulate_longterm.py --no-llm --sessions 8   # memory-only dry run
```

### Findings (30 sessions, 1,239 cut points, M2/Metal)

- **Memory helps, modestly and honestly**: top-1 next-word accuracy
  28.9% -> 29.2%, top-3 45.1% -> 45.5%; keystrokes saved 1,346 -> 1,387 ch.
  The 5-session mean of the per-session delta trends to **+2.0pp** by the
  end of the month (fig6) as habits accumulate.
- **Where it wins is the whole point**: the flips DPHM gets right are
  personal repeated content the base LLM cannot know — contact names in
  recurring phone lists (`carol`, `mccall`, `piper`, `linda`), recurring
  meeting phrases. Where the base LM is confident generic syntax, the
  confidence gate keeps memory silent (fusion flips only 16% of picks,
  and wins those flips 18:14).
- **Weighting is everything, and we measured it**: at 52% memory share the
  same memory *hurt* by 2pp (flipped 1/3 of picks, lost 2:1); at 21% it
  barely fired (+0.1pp). Confidence-gated interpolation (memory speaks
  only when the base LM is flat) is what turns the corner.
- **Latency budget holds**: DPHM hot path p50 ≈ 1.3 ms, p99 ≈ 9 ms per
  keystroke — ~100× cheaper than the llama.cpp logprobs call (p50 138 ms)
  it piggybacks on; the cold path (consolidation) is fully async.
- The full learning trajectory (per-session accuracy, memory growth,
  newly promoted habits, probe-prefix suggestions, win/loss examples) is
  human-readable in `results/longterm_sim.log`; figures in `results/figures/`.

## Setup (what `download.sh` does)

```bash
# 1. llama.cpp prebuilt binary
curl -sSL -o bin/llama.tar.gz \
  https://github.com/ggml-org/llama.cpp/releases/download/b9654/llama-b9654-bin-macos-arm64.tar.gz
tar -C bin -xzf bin/llama.tar.gz
xattr -dr com.apple.quarantine bin/llama-b9654   # clear macOS gatekeeper

# 2. models (Q4_K_M, ~3.1–3.4 GB each; community mirrors, no HF token needed)
curl -sSL -o models/gemma-4-E2B-base-Q4_K_M.gguf \
  https://huggingface.co/mradermacher/gemma-4-E2B-GGUF/resolve/main/gemma-4-E2B.Q4_K_M.gguf
curl -sSL -o models/gemma-4-E2B-it-Q4_K_M.gguf \
  https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf
```

## Run

```bash
# one model, interactively:
./run_server.sh models/gemma-4-E2B-base-Q4_K_M.gguf 99   # ngl=99 -> all layers on Metal GPU
python3 harness.py --label demo --n-predict 24 --temp 0 --out results/demo.json

# edit-in-the-middle test (cursor inside the text; scores suffix collision):
python3 harness.py --label mid --mid-cursor --n-predict 24 --temp 0 --out results/mid.json

# full experiment matrix (starts/stops the server itself):
./run_all.sh
```

## Reproduce the prefix-cache diagnosis

Why prefix caching doesn't help in the typing loop (see `WRITEUP.md` Q2). Start a
server, then run the probe chain — it prints a one-line verdict per step:

```bash
./run_server.sh models/gemma-4-E2B-base-Q4_K_M.gguf 99 > results/server.log 2>&1 &
python3 diagnose_cache.py --url http://127.0.0.1:8080 --server-log results/server.log
```

The probes, in order: **A** the cache works at all (identical resend reuses,
526→61 ms); **B** the growing-prefix loop re-encodes ~the whole prefix each step
(`prompt_n` grows); **C** it is *not* caused by generated tokens (`n_predict=1` vs
`24` are identical); **D** reuse only survives for short prefixes; **E** the smoking
gun in the server log — `n_swa = 512` and `erased invalidated context checkpoint`,
i.e. **Gemma 4 E2B's sliding-window attention** invalidates the KV checkpoints reuse
depends on. (Measured on gemma-4, not assumed from older Gemma.)

## Results at a glance (M2, Metal, Q4_K_M — full numbers in `WRITEUP.md`)

- Decode **≈ 38 tok/s**, prefill **≈ 409 tok/s**. Each *generated* token costs
  ~15× a *prefilled* one, so generation dominates total latency.
- Good config (base, greedy, `n_predict≈8`, stop at boundary): **TTFT ~230 ms,
  full short suggestion ~415 ms**.
- **GPU offload** is the big prefill win (3.0× vs CPU). **Capping suggestion
  length** is the big total-latency win (n=24→8: 713→415 ms).
- **Prefix caching barely helps in this loop** — Gemma 4 E2B's 512-token
  **sliding-window attention invalidates the KV checkpoints** reuse relies on
  (`n_swa = 512` in the server log). Reported straight; reproduce with
  `diagnose_cache.py`.
- **Base preferred over `-it`** for autocomplete: base continues in the writer's
  voice, `-it` drifts into a reviewer register (gap subtler on Gemma 4 than older
  Gemma). Same speed. See `EXAMPLES.md`.
- **Mid-document editing is the model's real weak spot** — being left-to-right, it
  ignores the suffix and **collides with already-written text on 47%** of in-the-middle
  edits (config H, `--mid-cursor`). A fill-in-the-middle model is the right tool there.

## What the harness measures

For each cut point along the passage it sends the growing prefix to the server's
`/completion` endpoint as a **streaming** request and records:

- **TTFT** — wall-clock to the first emitted token (what makes it feel instant)
- **total** — wall-clock to the full suggestion
- **prefill** (`prompt_ms` / `prompt_n`) — time/tokens to process the prefix
- **decode** (`predicted_ms` / `predicted_n`) — time/tokens to generate
- **word/char prefix match** — how many leading words/chars of the suggestion
  match the text the author actually wrote next (a *lower bound* on quality;
  raw suggestions are dumped for human judgement)

With **`--mid-cursor`** the harness instead simulates the cursor *inside* the text
(an edit-in-the-middle): it still sends only the prefix — a left-to-right model
cannot see the suffix — and scores the suggestion for **collision** with the
already-written suffix (`suffix_collision_rate`, `suffix_dup_lead_words_mean`,
`suffix_ngram_dup_rate`). Here overlap is the *failure* signal. On the email,
base collides with the suffix on **47%** of mid-document edits — the empirical
basis for `WRITEUP.md` Q4.
