# AI Proxy Server Design: Low-Latency Autocomplete Gateway

> **⚠️ SUPERSEDED (2026-06-01).** This design (Go/Fly + WebSocket + self-hosted Postgres/Redis) has been replaced by
> [`docs/llm-proxy-backend-design.md`](llm-proxy-backend-design.md)
> (Cloudflare Workers + SSE + Supabase). This doc also predates the Node.js sidecar removal / local llama.cpp inference.
> Kept for historical reference; see the new doc's "Why this supersedes the prior doc" section.

## Problem

Currently, the Autocomplete app calls OpenAI directly from the client (via the Node.js Sidecar). Users must provide their own API key. To scale as a consumer product, we need a server that:

1. Holds API keys so users don't need to manage them
2. Streams AI completions back with minimal added latency
3. Cancels inflight requests when the user keeps typing
4. Tracks usage for billing
5. Supports multiple AI providers with failover

## Architecture Overview

```
┌─────────────────┐     WebSocket      ┌──────────────────┐    HTTP/2 SSE    ┌─────────────┐
│  Autocomplete    │◄──────────────────►│   Proxy Server   │◄───────────────►│   OpenAI     │
│  (macOS app)     │  persistent conn   │   (Go, US-East)  │  connection     │   / Claude   │
│                  │  bidirectional     │                  │  pool           │   / etc.     │
└─────────────────┘                    └──────────────────┘                  └─────────────┘
                                              │
                                              │ reads/writes
                                              ▼
                                       ┌──────────────┐
                                       │  PostgreSQL   │
                                       │  (users, keys │
                                       │   usage logs) │
                                       └──────────────┘
```

## Why These Choices

### WebSocket (App ↔ Server)

The autocomplete app fires requests on every debounce (~300ms). With regular HTTP:
- Each request = TCP handshake + TLS negotiation = ~50-100ms overhead
- No way to push a cancel signal from client mid-request

With WebSocket:
- **One persistent connection** — zero per-request handshake overhead
- **Bidirectional** — client sends requests AND cancel signals; server streams tokens back
- **No silent buffering** — unlike SSE, WebSockets aren't buffered by corporate proxies or CDNs. SSE connections can appear open but batch events unpredictably in production environments
- **Heartbeat keepalive** — prevents idle timeout disconnections

This matches GitHub Copilot's approach: they use HTTP/2 specifically for its persistent multiplexed connections and cancellation propagation.

### HTTP/2 Connection Pool (Server ↔ OpenAI)

- **Multiplexing** — multiple inflight requests share one TCP connection
- **No per-request handshake** — connections are reused from a pool
- **Stream-level cancellation** — cancel one request without tearing down the connection
- **Flow control** — backpressure prevents overwhelming the client

### Go for the Server

- Best-in-class HTTP/2 library with fine-grained stream control (Copilot chose Go for this reason)
- `context.Context` propagates cancellation from WebSocket → HTTP/2 → OpenAI
- Goroutines handle thousands of concurrent connections with minimal memory
- Native concurrency model fits the streaming proxy pattern

### Single Region (US-East) to Start

- OpenAI inference runs in US datacenters
- Server in same region = ~5ms to OpenAI (vs ~100ms+ cross-continent)
- Most users are US-based initially
- Add edge regions later when user base grows globally

## Latency Budget

| Segment | Direct (current) | Via Proxy |
|---------|-------------------|-----------|
| App → OpenAI/Server | 30-80ms | 20-50ms (to proxy) |
| Server → OpenAI | — | 5-10ms (same region) |
| Server processing | — | <1ms |
| OpenAI first token | 200-800ms | 200-800ms |
| **Total to first token** | **230-880ms** | **225-860ms** |
| **Added overhead** | — | **~30-60ms** |

The proxy overhead is negligible compared to AI inference time. With connection pooling and reuse, the proxy path can actually be *faster* than direct client calls because the server maintains warm HTTP/2 connections to OpenAI.

## Protocol Design

### WebSocket Message Format

All messages are JSON, newline-delimited (consistent with current Sidecar IPC).

**Client → Server:**

```json
// Completion request
{
  "type": "request",
  "id": "req_abc123",
  "prefix": "Thank you for",
  "suffix": " about the project",
  "appName": "Mail",
  "windowTitle": "Re: Q3 Planning",
  "provider": "openai",
  "maxTokens": 100,
  "screenContext": "..."
}

// Cancel inflight request
{
  "type": "cancel",
  "id": "req_abc123"
}

// Ping (keepalive)
{
  "type": "ping"
}
```

**Server → Client:**

```json
// Streaming token
{
  "type": "token",
  "id": "req_abc123",
  "text": " looking"
}

// Completion finished
{
  "type": "complete",
  "id": "req_abc123",
  "text": " looking into this. I'll follow up tomorrow."
}

// Error
{
  "type": "error",
  "id": "req_abc123",
  "message": "Rate limit exceeded",
  "code": "rate_limited"
}

// Pong (keepalive response)
{
  "type": "pong"
}
```

This format is intentionally identical to the current Sidecar IPC protocol, minimizing client-side changes.

## Request Cancellation

Cancellation is the single biggest optimization for autocomplete. GitHub Copilot found that without cancellation, they'd make **twice as many requests** and waste half of them.

### Flow

```
User types 'h' → debounce → request req_001 sent
User types 'e' → cancel req_001 → debounce → request req_002 sent
User types 'l' → cancel req_002 → debounce → request req_003 sent
User stops    →                              → req_003 completes, tokens stream back
```

### Implementation

1. Client sends `{"type": "cancel", "id": "req_001"}` via WebSocket
2. Server receives cancel, calls `cancelFunc()` on the Go context for that request
3. Context cancellation propagates to the HTTP/2 stream to OpenAI via `request.Context()`
4. OpenAI stream is terminated — no more tokens billed
5. Server sends no further tokens for that request ID

The current app already implements this pattern in `AISidecar.swift` (`cancel(requestId:)`) and `Engine.swift` (`cancelCurrentRequest()`). The proxy server mirrors this behavior.

## Authentication & User Management

### Auth Flow

```
1. User signs up → gets account (email + password or OAuth)
2. App login    → POST /auth/login → receives JWT (short-lived) + refresh token
3. App connects → WebSocket with JWT in header: Authorization: Bearer <jwt>
4. Server validates JWT on connection, associates WebSocket with user
5. Token refresh → POST /auth/refresh with refresh token → new JWT
```

### JWT Structure

```json
{
  "sub": "user_abc123",
  "email": "user@example.com",
  "plan": "pro",
  "iat": 1711929600,
  "exp": 1711933200
}
```

- **Short-lived JWTs** (1 hour) — validated locally, no DB lookup per request
- **Refresh tokens** (30 days) — stored hashed in DB, one DB lookup on refresh
- **No per-request auth overhead** — JWT validated once at WebSocket connect time

### User Tiers

| Tier | Requests/day | Providers | Price |
|------|-------------|-----------|-------|
| Free | 50 | OpenAI (mini) | $0 |
| Pro | 1,000 | OpenAI, Claude | $10/mo |
| Unlimited | Unlimited | All providers | $25/mo |

## Usage Tracking & Billing

### Per-Request Logging

Every completion request logs:

```json
{
  "user_id": "user_abc123",
  "request_id": "req_xyz",
  "provider": "openai",
  "model": "gpt-4.1",
  "input_tokens": 150,
  "output_tokens": 42,
  "latency_ms": 340,
  "cancelled": false,
  "timestamp": "2026-03-20T10:00:00Z"
}
```

### Rate Limiting

- Enforced at the server per user, using a sliding window counter in Redis
- Exceeded → server sends `{"type": "error", "code": "rate_limited"}`
- No extra latency for non-rate-limited requests (check is O(1) in Redis)

### Billing

- Monthly aggregation of token usage per user
- Stripe integration for subscription management
- Usage-based overage billing for Unlimited tier if needed

## Provider Abstraction & Failover

```go
type Provider interface {
    Complete(ctx context.Context, req CompletionRequest, tokenCh chan<- string) error
}

// Implementations
type OpenAIProvider struct { ... }
type AnthropicProvider struct { ... }
type OllamaProvider struct { ... }
```

### Failover Strategy

1. Try primary provider (user's preference or default)
2. If primary returns 5xx or times out (>5s): fail over to secondary
3. Log the failover for monitoring
4. Circuit breaker: if a provider fails 5x in 60s, skip it for 30s

## Database Schema

```sql
CREATE TABLE users (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email       TEXT UNIQUE NOT NULL,
    plan        TEXT NOT NULL DEFAULT 'free',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE refresh_tokens (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID REFERENCES users(id),
    token_hash  TEXT NOT NULL,
    expires_at  TIMESTAMPTZ NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE usage_logs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID REFERENCES users(id),
    request_id      TEXT NOT NULL,
    provider        TEXT NOT NULL,
    model           TEXT NOT NULL,
    input_tokens    INT NOT NULL,
    output_tokens   INT NOT NULL,
    latency_ms      INT NOT NULL,
    cancelled       BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_usage_user_date ON usage_logs(user_id, created_at);
```

## Server Components

```
proxy-server/
├── cmd/
│   └── server/
│       └── main.go              # Entry point, config loading
├── internal/
│   ├── auth/
│   │   ├── jwt.go               # JWT generation & validation
│   │   └── middleware.go        # WebSocket auth middleware
│   ├── proxy/
│   │   ├── handler.go           # WebSocket handler, message routing
│   │   ├── session.go           # Per-connection state, request tracking
│   │   └── cancellation.go      # Context-based cancellation logic
│   ├── provider/
│   │   ├── provider.go          # Provider interface
│   │   ├── openai.go            # OpenAI HTTP/2 streaming client
│   │   ├── anthropic.go         # Anthropic client
│   │   └── failover.go          # Circuit breaker, failover logic
│   ├── ratelimit/
│   │   └── limiter.go           # Redis-based sliding window
│   ├── usage/
│   │   └── tracker.go           # Async usage logging
│   └── db/
│       └── postgres.go          # Database connection & queries
├── Dockerfile
├── fly.toml                     # Fly.io deployment config
├── go.mod
└── go.sum
```

## Client-Side Changes

Minimal changes needed in the macOS app:

1. **New connection mode** in `AISidecar.swift` — connect via WebSocket instead of spawning a local Node.js process
2. **Auth flow** — login screen or token storage in Keychain (extends existing `KeychainManager`)
3. **Fallback** — if server unreachable, fall back to direct API call with user's own key
4. **Toggle** — Settings menu: "Use Autocomplete Cloud" vs "Use own API key"

The WebSocket message format is identical to the current Sidecar IPC, so `Engine.swift` needs no changes — only the transport layer changes.

## Deployment

### Phase 1: Single Region

```
Fly.io (US-East / iad)
├── 2x shared-cpu-2x (Go server)     ~$10/mo
├── PostgreSQL (1GB)                  ~$7/mo
├── Redis (via Upstash, free tier)    $0
└── Total                             ~$17/mo
```

### Phase 2: Multi-Region (when needed)

```
Fly.io
├── US-East (iad) — primary, nearest to OpenAI
├── EU-West (ams) — European users
├── Asia (nrt)    — Asian users
└── PostgreSQL with read replicas per region
```

Fly.io supports WebSocket connections natively and can route users to the nearest region automatically.

## Implementation Phases

### Phase 1: Core Proxy (Week 1-2)
- Go server with WebSocket handler
- OpenAI provider with HTTP/2 streaming
- Request cancellation via context
- Basic API key auth (hardcoded keys for testing)

### Phase 2: Auth & Users (Week 3)
- JWT auth with login/signup endpoints
- PostgreSQL user storage
- Keychain integration on client side
- "Use Cloud" toggle in settings

### Phase 3: Usage & Billing (Week 4)
- Usage logging to PostgreSQL
- Rate limiting via Redis
- Stripe subscription integration
- Usage dashboard (simple web page)

### Phase 4: Production Hardening (Week 5)
- Provider failover & circuit breaker
- Monitoring & alerting (Prometheus + Grafana or Fly.io metrics)
- Multi-region deployment
- Load testing

## Security Considerations

- **API keys** stored encrypted in server env vars (Fly.io secrets), never in code
- **JWT secrets** rotated periodically, stored in Fly.io secrets
- **User data** — only email and usage metrics stored; no completion text logged
- **TLS everywhere** — WebSocket over WSS, HTTP/2 to providers
- **Rate limiting** prevents abuse of shared API keys
- **No completion content stored** — prefix/suffix/completions are proxied in memory only, never persisted

## Monitoring

Key metrics to track:
- **P50/P95/P99 first-token latency** (most critical)
- **Request cancellation rate** (should be ~50% per Copilot's data)
- **Provider error rate** and failover frequency
- **Active WebSocket connections**
- **Token usage per user per day**
- **Server CPU and memory utilization**

## References

- [How GitHub Copilot Serves 400M Completions/Day](https://www.infoq.com/presentations/github-copilot/)
- [Building a Low-Latency Global Code Completion Service](https://www.zenml.io/llmops-database/building-a-low-latency-global-code-completion-service)
- [Streaming AI Responses with HTTP/2 in Go](https://dasroot.net/posts/2026/02/streaming-ai-responses-http2-go/)
- [SSE vs WebSocket for AI Streaming](https://medium.com/@pranavprakash4777/streaming-ai-responses-with-websockets-sse-and-grpc-which-one-wins-a481cab403d3)
- [LiteLLM — Open Source LLM Gateway](https://github.com/BerriAI/litellm)
- [Fly.io WebSocket Support](https://fly.io/blog/websockets-and-fly/)
- [Cloudflare Workers AI Streaming](https://blog.cloudflare.com/workers-ai-streaming/)
