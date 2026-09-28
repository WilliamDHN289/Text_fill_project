# Server-Side LLM Proxy + Auth Backend — Design

**Date:** 2026-06-01
**Status:** Draft — awaiting review
**Supersedes:** `docs/proxy-server-design.md` (Go/Fly + WebSocket + self-hosted Postgres/Redis). That doc predates the removal of the Node.js sidecar and the move to local llama.cpp inference, and chose a different architecture. See §"Why this supersedes the prior doc".

---

## 1. Context & Problem

Today the app has **no backend of its own**. It is a "fat client": the macOS app holds everything that would normally live server-side.

- **API keys** — AES-encrypted but embedded in `CloudProvider.swift`, shipped to every user. Extractable from the binary; the spend cap is the only real defense.
- **System prompt + prompt-wrapping logic** — encrypted in the client. Cannot change without shipping an app release.
- **Provider/model selection + base URLs** — hardcoded (encrypted) in the client.
- **Access gating** — invite codes validated entirely on-device (`InviteCodeManager`, Keychain). No real metering or revocation.

The only remote things the app touches are third-party APIs (OpenAI/OpenRouter/Qwen, called directly) and static file hosting (model download in `ModelManager`, Sparkle appcast/DMGs on GitHub). None of these is an application backend we control.

**This project introduces the app's first backend: an authenticated, low-latency streaming proxy.** The client will call *our* server, which holds the keys + prompts and forwards to the LLM provider.

## 2. Goals / Non-Goals

**Goals**
- **Protect API keys** — keys leave the client entirely; live only as server-side secrets. Rotate without a release.
- **Protect prompts as IP** — system prompt + wrapping logic move server-side.
- **Central control** — swap models/prompts and (Phase 2) meter + rate-limit per user without an app update.
- **Real auth** — accounts (email login) via Supabase; usage tied to an authenticated user.
- **Latency** — the proxy must add **≤ ~50ms** over calling the provider directly, on the warm path. This is the binding constraint.

**Non-Goals (Phase 1)**
- Billing / Stripe / paid tiers.
- Multi-provider failover + circuit breaker.
- Multi-region deployment.
- Instant (sub-token-TTL) revocation.
- Voice / Realtime / WebSocket transport.

## 3. Architecture Overview

```
TODAY (fat client, no backend)              TARGET (client + a backend we own)
┌─────────────────────────┐                ┌──────────────────┐   ┌───────────────────────┐
│  macOS app              │                │  macOS app       │   │  Cloudflare Worker     │
│  • UI, capture, insert  │                │  • UI, capture   │   │  (edge, our proxy)     │
│  • local inference      │   ─────────►   │  • local infer.  │──►│  • verify Supabase JWT │
│  • API keys  🔓         │   SSE stream   │  • Supabase JWT  │   │  • inject key + prompt │
│  • system prompt 🔓     │                │    (Keychain)    │◄──│  • stream SSE through  │
│  • invite codes (local) │                └────────┬─────────┘   └───────────┬───────────┘
└───────────┬─────────────┘                login/   │                         │ HTTP/2 SSE
            │ direct, key in client         refresh  ▼                         ▼  (pooled)
            ▼                               ┌──────────────────┐      ┌─────────────────┐
   OpenAI / OpenRouter                      │  Supabase        │      │  OpenAI         │
                                            │  • Auth (JWT)    │      └─────────────────┘
                                            │  • JWKS endpoint │
                                            │  • Postgres (P2) │
                                            └──────────────────┘
```

- **macOS app (frontend):** UI, context capture, insertion, **local llama.cpp inference** (kept — it is the offline/fallback path). Logs in via Supabase, stores the JWT in Keychain, sends it on each completion request.
- **Cloudflare Worker (the new backend):** edge proxy. Verifies the Supabase JWT locally, injects the real API key + system prompt, forwards to the provider, and **streams the SSE response straight back**. Chosen for zero cold start on sparse beta traffic + edge proximity (see latency budget).
- **Supabase:** managed auth (accounts, email login, JWT issuance, JWKS endpoint) and, in Phase 2, Postgres for usage logs. **Off the completion hot path** — the Worker never calls Supabase per request.
- **OpenAI:** the LLM provider. Single provider in Phase 1 (direct, to avoid an extra hop).

## 4. Components

### 4.1 macOS client changes
Grounded in current files; intentionally minimal.

- **`CloudProvider.swift`:** point the request at the Worker's `/v1/complete` endpoint; send `Authorization: Bearer <supabase_jwt>` instead of the provider key. Remove the embedded `_openaiKey` / `_openrouterKey` and the encrypted base URLs/model config (these move server-side). Keep the existing streaming consumer (`streamResponse`) — the Worker passes the provider's SSE through unchanged, so the parser is unaffected.
- **Auth/login UI (new):** a small login view using the Supabase Swift SDK. Stores the session (access + refresh token) in Keychain via the existing `KeychainManager`. Refresh handled by the SDK in the background.
- **Fallback:** when not logged in, offline, the Worker is unreachable, or a request is rate-limited → fall back to **local llama.cpp inference** (`LlamaProvider`). This is the graceful-degradation path and replaces today's "use your own key" fallback.
- **Cancellation:** keep the existing `Engine.cancelCurrentRequest()` behavior — cancel the in-flight `URLSession` task on a new keystroke (see §8).
- **Invite codes:** `InviteCodeManager` stays as-is in Phase 1; its relationship to accounts is an open decision (§12).

### 4.2 Cloudflare Worker (proxy)
- **Endpoint:** `POST /v1/complete`, returns `text/event-stream`.
- **Auth:** verify the Supabase JWT locally via JWKS (§6). Reject with 401 on failure. **No network call to Supabase per request.**
- **Request build:** read the completion payload (prefix/suffix/app context, mirroring `CompletionRequest`), inject the server-held API key + system prompt + model, build the upstream OpenAI chat-completions request with `stream: true`.
- **Streaming passthrough:** return `new Response(upstream.body, …)` (optionally a `TransformStream` only if reformatting is required). **Never buffer** the full completion.
- **Cancellation propagation:** wire an `AbortController` to the upstream `fetch`; abort it when the client disconnects (§8).
- **Config:** API key, system prompt, model name held as **Worker secrets/env vars** (Phase 1). Changeable with a `wrangler deploy` — fast, no app release. (Phase 2 may move prompt/model to a cached Supabase config table for no-deploy changes.)
- **Usage logging (Phase 2):** fire-and-forget to Supabase Postgres via `ctx.waitUntil()` — after the response, never blocking it.
- **Rate limiting (Phase 2):** Workers KV counter, O(1), at the edge.

### 4.3 Supabase
- **Auth:** email login (method TBD §12), JWT issuance (~1h access token + refresh token), **asymmetric signing keys** with a JWKS endpoint.
- **Postgres (Phase 2):** `usage_logs` (no completion content — see §10). Accounts are managed by Supabase Auth's own tables.
- **Region:** a US region (off the hot path; see §7). Final choice in §12.

## 5. Request Lifecycle & Data Flow

**Login (once per session, off hot path):** app → Supabase login → receives JWT + refresh token → stored in Keychain. Latency irrelevant (UI flow).

**Completion (the hot path):**
1. App sends `POST /v1/complete` with `Bearer <JWT>` over a reused HTTP/2 connection. *(~5–15ms)*
2. Worker verifies JWT locally + injects key/prompt/model + builds upstream request. *(~1–5ms)*
3. Worker `fetch()`s OpenAI (pooled connection). *(~10–30ms)*
4. **Model generates** — time to first token. *(~200–800ms; same regardless of hosting)*
5. First SSE chunk → Worker → client, streamed through. *(~15–45ms back)*
6. Tokens 2..N stream at the model's rate; `[DONE]` closes the stream.

**Token refresh (~hourly, off hot path):** Supabase SDK refreshes the access token in the background before expiry.

**Offline / failure:** any of {not logged in, no network, Worker 5xx/unreachable, 429 rate-limited} → app uses **local llama.cpp inference** instead.

## 6. Auth Design (JWT + JWKS, edge-local verification)

- Supabase issues a **signed JWT**; the Worker verifies the **signature locally** using Supabase's published **JWKS** public keys. This is the core efficiency decision: **no per-request network call to Supabase.**
- Use **asymmetric signing keys** (not the legacy shared HS256 secret). The Worker holds only *public* keys → it cannot forge tokens, and rotation is graceful.
- Use a remote-JWKS client (e.g. `jose`'s `createRemoteJWKSet`) that:
  - **caches** the JWKS,
  - **refetches on an unknown `kid`** (how it learns about a rotation — the new key's `kid` in a token triggers the refresh; no push/webhook needed),
  - applies a **cooldown** (e.g. 30s) so bogus `kid`s can't cause a fetch storm,
  - applies a **`cacheMaxAge`** (e.g. 6–24h) as a TTL backstop.
- **Rotation** is admin-initiated (no fixed auto-schedule). During rotation Supabase keeps the old key in the JWKS until old tokens expire (overlap window), so no token is ever rejected mid-switch.
- **Revocation lag:** with local verification, a revoked user's token stays valid until it expires (≤ ~1h). Acceptable for the beta. If instant revocation is later needed: shorten token lifetime or add a Workers KV denylist check (a few ms at the edge, still no Supabase call).
- **Cloudflare wrinkle:** isolates are ephemeral, so the in-memory JWKS cache lives per-isolate. Fine for beta volume; if minimizing fetches matters later, share the JWKS via the Cache API / KV.

## 7. Latency Budget

Warm path, US user, direct OpenAI, pooled connections:

| Segment | Latency |
|---|---|
| client → edge (request) | ~5–15ms |
| Worker (JWT verify + build) | ~1–5ms |
| edge → OpenAI (request) | ~10–30ms |
| **model TTFT** (provider compute, hosting-independent) | **~200–800ms** |
| OpenAI → edge → client (first token) | ~15–45ms |
| **Proxy's own added cost vs. direct** | **~10–50ms** |

The proxy overhead is small next to model TTFT. Supabase adds ~1–5ms (local JWT verify) and **no network hop**. Subsequent tokens stream at the model's rate; the proxy adds a constant ~one-RTT pipeline delay, not a per-token cost.

**Why Cloudflare Workers:** sparse beta traffic makes **cold starts** the dominant risk to *mean/median* latency. Workers (V8 isolates) have effectively zero cold start, unlike scale-to-zero Lambda/containers. Edge proximity keeps `client→edge` short for all users.

*Per-step measurement of these segments (to validate the budget and catch regressions) is covered in §14 — Observability.*

## 8. Cancellation

Autocomplete cancels constantly (the user keeps typing; old suggestions go stale). Handled **without** WebSocket:

1. On a new keystroke, the client cancels the in-flight `URLSession` task (existing `Engine.cancelCurrentRequest()`).
2. That sends HTTP/2 `RST_STREAM` (or closes the connection), which the Worker observes as a client disconnect.
3. The Worker aborts the upstream `fetch` via its `AbortController` → OpenAI stream terminates → no further tokens generated/billed.

This matches the existing client cancellation pattern; only the transport changes.

## 9. Error Handling & Fallback

| Condition | Behavior |
|---|---|
| Not logged in | Use local llama.cpp inference |
| Offline / Worker unreachable / 5xx | Use local llama.cpp inference |
| 429 rate-limited (Phase 2) | Use local llama.cpp inference; surface a gentle notice |
| Access token expired | Supabase SDK refreshes; retry once |
| Invalid/forged token | Worker returns 401; client re-auths |

Local inference as the fallback is a deliberate strength of this architecture — the app stays useful offline and during any backend outage.

## 10. Security Model

- **Protected:** API keys and system prompt exist only as server-side secrets (Worker env / Supabase). The client binary no longer contains them.
- **Client holds:** only a short-lived Supabase session JWT (in Keychain). Compromise exposes one user's quota until token expiry, not the keys.
- **No completion content persisted:** prefix/suffix/completions are proxied in memory only; Phase 2 usage logs store metrics (tokens, latency, user id, timestamp) — **never the text**, and **never model identifiers in plaintext** in logs or code.
- **TLS everywhere:** client↔Worker and Worker↔provider.
- **Threat residue:** revocation lag (§6); a leaked JWT is bounded by its TTL.

## 11. Phasing

**Phase 1 — Proxy + Auth (the core).**
- Cloudflare Worker `/v1/complete` with edge-local JWT verification.
- Single provider (direct OpenAI); key + prompt + model as Worker secrets.
- SSE passthrough + cancellation propagation.
- Supabase email login; client login UI + Keychain storage.
- Client points at the Worker; embedded cloud keys removed; local inference becomes the fallback.
- **Exit criteria:** a logged-in user gets cloud completions through the Worker; no keys/prompts in the client binary; warm-path overhead measured ≤ ~50ms; offline falls back to local.

**Phase 2 — Central control.**
- Async usage logging (Postgres via `ctx.waitUntil()`).
- Per-user rate limiting (Workers KV).
- Optional: move prompt/model to a cached Supabase config table for no-deploy changes / prompt A-B.

**Phase 3 — Deferred (from the prior doc, explicitly out of scope now).**
- Billing/Stripe + tiers, multi-provider failover + circuit breaker, multi-region. Revisit only when the user base and product justify them.

## 12. Open Decisions (confirm before the implementation plan)

1. **Login method** — default **email + password** (simplest self-contained native form; no URL-scheme redirect handling). Alternatives: magic link or OAuth (need a custom URL-scheme callback in the macOS app).
2. **Invite codes vs. accounts** — keep `InviteCodeManager` as-is, *or* make a valid invite code a **signup gate** (closed beta), *or* retire it in favor of account-based access. Default: keep as-is in Phase 1, decide gating later.
3. **Embedded-key removal timing** — remove the embedded cloud keys in the same release that ships the proxy (recommended), vs. keep them as a temporary dev fallback behind a flag.
4. **Supabase region** — default a US region (near you/provider); confirm based on where beta users actually are.
5. **Prompt/model config** — Phase 1 default is Worker env/secrets (redeploy to change). Confirm whether no-deploy changes (config table) are wanted earlier.

## 13. Testing Strategy

- **Unit:** JWT verification (valid, expired, wrong `kid`, forged); request-build/transform.
- **Integration:** end-to-end streaming passthrough; cancellation propagation (client abort → upstream abort); fallback paths (offline, 401, 5xx, 429).
- **Latency:** reuse the existing `[Latency]` logging in `Engine.swift` to measure warm-path overhead against the ≤50ms target; compare proxy vs. direct. Full instrumentation in §14.
- **Manual QA:** debug build, per standing preference to rebuild/relaunch the debug instance during QA loops.

## 14. Observability / Latency Instrumentation

Because the Worker sits in the middle of the round trip, it is the instrumentation point that makes per-step attribution possible — the client alone only sees the aggregate (request sent → first token).

**Worker phase timestamps** (recorded per request):
- `t_in` — request received at the Worker
- `t_fetchStart` — upstream `fetch()` initiated (after JWT verify + build)
- `t_firstChunk` — first SSE chunk received from the provider
- `t_lastChunk` — upstream stream complete

Derived segments:
- `authBuildMs = t_fetchStart − t_in` — auth + request build (expect a few ms)
- `upstreamTtftMs = t_firstChunk − t_fetchStart` — **bundled** edge→LLM network + model time-to-first-token
- `streamMs = t_lastChunk − t_firstChunk` — token streaming duration
- `workerSpanMs = t_firstChunk − t_in` — the Worker's view of total-to-first-token

**Client measurement.** The existing `[Latency]` log in `Engine.swift` records end-to-end TTFT (`E2E_client = firstTokenReceived − requestSent`) and total completion time.

**Inferring the network leg (no synced clocks needed).** One-way network time can't be measured directly across machines (clock skew). But the **client↔edge round trip** is derivable by subtracting two single-clock durations:

```
client↔edge network (both legs) ≈ E2E_client − workerSpanMs
```

This is clock-skew-immune because each term is a duration on one clock. The `edge→LLM` network stays bundled into `upstreamTtftMs`; it's small and stable, so variance there is attributable to the model. (A periodic lightweight upstream ping can estimate the network baseline if a split is ever needed.)

**Surfacing the timings — three complementary mechanisms:**
1. **`Server-Timing` response header** — carries the *pre-stream* phases (e.g. `auth`) the client can read off the response. Limited to what's known before the SSE body flushes, since headers are sent first.
2. **Final SSE `timing` event** — the Worker emits one synthetic event as the *last* item in the stream with the full breakdown (`authBuildMs`, `upstreamTtftMs`, `streamMs`, `workerSpanMs`). The client already parses SSE, so this is the clean channel for end-of-request numbers.
3. **Cloudflare Workers Analytics Engine** (or `console.log` → Logpush) — one structured data point per request, all segments as dimensions. Primary home for aggregate **median/P50** dashboards across all traffic without burdening the client — aligned with tracking mean/median rather than one-off traces.

**Client log extension.** Extend `Engine.swift`'s `[Latency]` line to record `E2E_client`, the Worker breakdown (from the timing event), and the inferred client↔edge network — giving full per-step attribution to validate the ≤50ms overhead target and catch regressions.

**No content in telemetry.** Timing/metrics only — never prefix/suffix/completion text, and no plaintext model identifiers (consistent with §10).

## 15. Out of Scope

Billing/tiers, multi-region, multi-provider failover, instant revocation, voice/Realtime/WebSocket transport. (WebSocket is only revisited if a Realtime/voice feature lands — it would also change the platform choice.)

## Why this supersedes the prior doc

`docs/proxy-server-design.md` chose **Go on Fly.io + WebSocket + self-hosted Postgres/Redis auth + Stripe tiers**. This design diverges deliberately:
- **Transport:** SSE over HTTP/2, not WebSocket. The prior doc's main WebSocket argument (per-request TCP/TLS handshake cost) assumes no HTTP/2 keep-alive; with connection reuse that cost disappears. Cancellation is handled by HTTP/2 stream abort, and WebSocket on Workers would require Durable Objects (pinned region, losing the edge advantage).
- **Platform:** Cloudflare Workers (zero cold start, edge) over single-region Fly/Go — chosen specifically for mean/median latency on sparse beta traffic.
- **Auth:** managed Supabase over self-rolled JWT + Postgres + Redis — far less to build and own.
- **Local inference:** this design treats llama.cpp as the offline/fallback path; the prior doc predates the sidecar removal and never accounts for it.
- **Billing/failover/multi-region** are deferred (Phase 3), not front-loaded.

## References

- [How GitHub Copilot Serves 400M Completions/Day](https://www.infoq.com/presentations/github-copilot/) — cancellation economics.
- [Cloudflare Workers AI Streaming](https://blog.cloudflare.com/workers-ai-streaming/)
- Supabase docs — JWT signing keys / JWKS, Swift SDK (confirm current rotation UI before building; product knobs evolve).
- `jose` — `createRemoteJWKSet` (JWKS caching + `kid`-miss refetch + cooldown).
