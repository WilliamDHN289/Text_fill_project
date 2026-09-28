# MVP Architecture Design: macOS System-Wide Autocomplete

**Date:** 2026-02-06
**Status:** Approved (Phase 2)

## Goal
Build a macOS menu bar app that shows AI-powered text suggestions as you type in any application.

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                    macOS Autocomplete App (Swift)                │
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────────┐  │
│  │  InputMonitor │    │  Engine       │    │  Renderer          │  │
│  │  (CGEventTap) │───>│  (Core Logic) │───>│  (Overlay+Toolbar) │  │
│  └──────────────┘    └──────┬───────┘    └───────────────────┘  │
│                             │                                    │
│  ┌──────────────┐           │           ┌───────────────────┐   │
│  │  ContextReader│<──────────┘           │  SettingsManager   │   │
│  │  (AX API)     │                       │  (UserDefaults)    │   │
│  └──────────────┘                       └───────────────────┘   │
│                                                                  │
│  ┌──────────────┐                       ┌───────────────────┐   │
│  │  TextInserter │                       │  MenuBarController │   │
│  │  (AX/Clipboard│                       │  (NSStatusItem)    │   │
│  └──────────────┘                       └───────────────────┘   │
└──────────────────────────────┬───────────────────────────────────┘
                               │ IPC (Unix socket)
                          ┌────┴─────────────────┐
                          │  AI Sidecar (Node.js) │
                          │  - OpenAI provider    │
                          │  - OpenRouter provider│
                          │  - Ollama provider    │
                          │  - Qwen provider      │
                          └──────────────────────┘
```

## Components

### InputMonitor (Input/InputMonitor.swift)
- CGEventTap with `.defaultTap` option
- Captures keyDown events, extracts keyCode + Unicode characters
- Detects Tab, Right Arrow, Escape for suggestion control
- Checks `IsSecureEventInputEnabled()` on each event
- Requires: Accessibility permission

### ContextReader (Context/ContextReader.swift)
- AX API wrapper: focused app → focused element → text + caret + bounds
- Reads: kAXValueAttribute (text), kAXSelectedTextRangeAttribute (caret), kAXBoundsForRangeAttribute (screen rect)
- Detects password fields via kAXSecureTextFieldSubrole
- Detects font via kAXAttributedStringForRangeAttribute (best effort)
- Returns nil for non-text elements

### Engine (Engine/Engine.swift)
- Central orchestrator
- Debounce timer (300ms, configurable)
- Trigger heuristics: end-of-text, end-of-line, after space/punctuation
- Suppression: password fields, secure input, disabled apps, mid-text, rapid deletion
- Cache forwarding: if user types chars matching cached suggestion, trim and re-show
- Request cancellation: cancel in-flight on every new keystroke
- Post-processing: overlap trimming via trimOverlap(suggestion, prefix, suffix)

### AISidecar (AI/AISidecar.swift + Sidecar/)
- Swift side: launches Node.js process, communicates via Unix domain socket
- TS side: receives completion requests, routes to provider, streams tokens back
- Protocol: JSON messages over Unix socket, newline-delimited
- Messages: { type: "request" | "cancel" | "token" | "complete" | "error", ... }
- Providers: OpenAI (official SDK), OpenRouter (OpenAI-compatible), Ollama (local HTTP), Qwen (API)

### Renderer (Renderer/)
- SuggestionPanel: NSPanel with .nonactivatingPanel, .floating, ignoresMouseEvents
- Ghost text: gray, ~50% opacity, fade in 150ms / out 100ms
- Positioned at caret screen rect (AX top-left → AppKit bottom-left conversion)
- ToolbarPanel: small floating controls near text field for enable/disable
- Multi-monitor aware, Retina-safe

### TextInserter (Insertion/TextInserter.swift)
- Primary: AX kAXSelectedTextAttribute insertion
- Fallback: clipboard injection (save clipboard → paste → restore)
- Partial insertion for word-by-word acceptance

### SettingsManager (Settings/SettingsManager.swift)
- UserDefaults-backed persistence
- Global enable/disable, per-app disable list, active provider, API keys, debounce interval, trigger mode

### MenuBarController (App/MenuBarController.swift)
- NSStatusItem with dropdown menu
- Shows: enabled/disabled status, current provider, settings access, quit

## Key Bindings
| Key | Action |
|-----|--------|
| Tab | Accept entire suggestion |
| Right Arrow | Accept one word |
| Escape | Dismiss suggestion |

## UX Rules
- Debounce: 300ms after last keystroke
- Only suggest at end of text or end of line (not mid-text for MVP)
- Skip password fields and Secure Input mode
- Cache forwarding when user types matching characters
- Fade in 150ms, fade out 100ms
- Max suggestion: ~50 words / end of sentence
- Contextual toolbar appears near text field when autocomplete active

## Safety
- Never suggest in password fields
- Respect Secure Input mode (pause all monitoring)
- Never log/persist raw keystrokes
- Only send text context to AI when suggestion triggered

## AI Providers (MVP)
| Provider | SDK | Use Case |
|----------|-----|----------|
| OpenAI | Official TS SDK | GPT-4o-mini for fast completions |
| OpenRouter | OpenAI-compatible | Access to Claude, Llama, Mistral, etc. |
| Ollama | Local HTTP | On-device models, offline, private |
| Qwen | Qwen API | Qwen2.5-Coder, strong code/text |

## IPC Protocol (Swift ↔ Node.js)
Unix domain socket at /tmp/autocomplete-sidecar.sock

```json
// Request (Swift → Node.js)
{"type":"request","id":"req-123","prefix":"Hello ","suffix":"","app":"TextEdit","provider":"openai","maxTokens":100}

// Cancel (Swift → Node.js)
{"type":"cancel","id":"req-123"}

// Token (Node.js → Swift)
{"type":"token","id":"req-123","text":"world"}

// Complete (Node.js → Swift)
{"type":"complete","id":"req-123","text":"world, how are you?"}

// Error (Node.js → Swift)
{"type":"error","id":"req-123","message":"API key invalid"}
```

## Implementation Order
1. Project setup (Xcode + Node.js)
2. InputMonitor (CGEventTap keystroke capture)
3. ContextReader (AX API text + caret reading)
4. Renderer (NSPanel overlay at caret position)
5. Engine (debounce + trigger logic, wire InputMonitor → ContextReader → Renderer)
6. AISidecar (Node.js process + IPC + one provider)
7. Wire Engine → AISidecar → Renderer (end-to-end suggestion flow)
8. TextInserter (accept suggestions via Tab/Right Arrow)
9. Cache forwarding
10. Add remaining providers (OpenRouter, Ollama, Qwen)
11. SettingsManager + MenuBarController
12. Contextual toolbar
13. Polish: animation, font matching, edge cases
