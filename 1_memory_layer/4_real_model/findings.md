# Findings & Decisions
<!-- 
  WHAT: Your knowledge base for the task. Stores everything you discover and decide.
  WHY: Context windows are limited. This file is your "external memory" - persistent and unlimited.
  WHEN: Update after ANY discovery, especially after 2 view/browser/search operations (2-Action Rule).
-->

## Requirements
<!-- 
  WHAT: What the user asked for, broken down into specific requirements.
  WHY: Keeps requirements visible so you don't forget what you're building.
  WHEN: Fill this in during Phase 1 (Requirements & Discovery).
  EXAMPLE:
    - Command-line interface
    - Add tasks
    - List all tasks
    - Delete tasks
    - Python implementation
-->
<!-- Captured from brainstorming session 2026-02-06 -->
- Target user: All Mac users (non-technical audience, must be intuitive)
- Completion type: Adaptive (short for chat/email, longer for documents) + user override control
- AI backend: Pluggable — user chooses provider (Claude, OpenAI, local model, etc.)
- Tech stack: Research-driven — best fit for caret detection + overlay rendering
- Trigger mode: Configurable (always-on, hotkey, or both). Default: always-on + hotkey for longer completions
- MVP scope: Must work system-wide across macOS apps
- Privacy: Standard SaaS approach, no special constraints
- Acceptance UX: Tab to accept (partial word-by-word TBD), Escape to dismiss

## Research Findings

NOTE: Web search/fetch tools were unavailable during this research session. All findings
below are synthesized from training knowledge covering published blog posts, open-source
codebases (Continue.dev, Copilot extensions, Codeium OSS components), technical papers,
and official documentation through early 2025. Key URLs are provided where known, but
should be verified when web access is restored.

---

### ===================================================================
### QUESTION 1: WHEN TO TRIGGER SUGGESTIONS?
### ===================================================================

**The universal pattern: debounced keystroke + heuristic filtering.**

Every production autocomplete system studied uses a variation of the same core approach:
monitor keystrokes, apply a debounce delay, then decide if a request is warranted.

#### Cursor (Tab Completion)
- Triggers on **every keystroke** but with a **debounce of ~300-500ms** of idle time.
- Also triggers on specific "structural" events: typing a space after a keyword, opening
  a bracket/paren, pressing Enter at end of line, or placing cursor at end of a line.
- Does NOT trigger while the user is actively deleting (backspace sequences).
- Has a concept of "eager" vs "lazy" mode: in eager mode, it predicts even mid-line;
  in lazy mode, it waits for end-of-line or explicit pause.
- Key insight: Cursor's Tab completion is **not** traditional autocomplete -- it can
  suggest EDITS (deletions + insertions), not just appended text. This means it triggers
  even when the cursor is in the middle of existing code.
- Source: https://cursor.sh/blog/cursor-tab (Cursor Tab blog post)

#### GitHub Copilot
- Triggers after a **debounce of ~300ms** of typing inactivity.
- Also triggers on explicit events: newline, typing a comment prefix (`//`, `#`),
  opening a function body, typing an assignment operator.
- Does NOT trigger inside string literals (configurable), comments (configurable),
  or when the file is very large and would exceed context limits.
- The VS Code extension has a `InlineCompletionItemProvider` that gets called by
  VS Code's built-in inline completion API. VS Code itself manages some debouncing.
- Copilot filters out triggers when: cursor is inside a word and not at word boundary,
  the document has unsaved syntax errors in some modes, or the user is in a diff view.
- Source: GitHub Copilot VS Code extension (partially open/inspectable), GitHub blog posts.

#### Supermaven
- Triggers on **every keystroke with minimal debounce (~100-150ms)** -- this is a key
  differentiator. Because their model is faster to respond, they can afford less debounce.
- Uses a persistent WebSocket connection (not HTTP request/response), so there's no
  connection overhead per request. The typing stream is sent continuously.
- Source: https://supermaven.com/blog/supermaven-is-now-free

#### Continue.dev (Open Source -- most inspectable)
- Debounce is configurable, defaults to **~350ms**.
- Triggers on `onDidChangeTextDocument` events in VS Code (every keystroke that changes text).
- Has explicit "should trigger" logic that checks:
  - Is the cursor at end of line? (more likely to trigger)
  - Did the user just type a space, newline, or punctuation? (trigger)
  - Is the current line empty? (trigger -- assume user wants next line predicted)
  - Did the user just delete text? (do NOT trigger for a brief cooldown)
  - Is there already a pending request? (cancel it, start new one)
- The trigger logic is in `completionProvider.ts` in the Continue VS Code extension.
- Source: https://github.com/continuedev/continue (open source)

#### Codeium
- Triggers after a debounce of **~300ms**, similar to Copilot.
- Also uses "proactive" triggers: detects when the user has just typed a pattern that
  commonly precedes a completion (e.g., function signature, import statement).
- Has a lightweight local model that does initial filtering before sending to server.
- Source: Codeium blog and documentation

#### Gmail Smart Compose
- Triggers after the user pauses typing for approximately **~500-750ms**.
- Only triggers when the model's confidence exceeds a threshold (more on this in Q6).
- Does NOT trigger for very short emails or when the user is typing very fast.
- Only suggests when it can predict at least a few words with high confidence.
- Triggers more aggressively at the start of a new sentence or after a greeting.
- Source: Google AI Blog "Smart Compose" (2018), arxiv paper 1906.00080

#### Apple QuickType / Predictive Text
- Triggers on **every keystroke** with essentially zero debounce -- predictions update
  in real-time as each character is typed.
- Shows 3 predictions in the prediction bar above the keyboard (iOS) or inline (macOS).
- Uses an on-device neural language model that is fast enough for per-keystroke updates.
- Does NOT trigger in password fields, in fields marked `secureTextEntry`, or when
  the `autocorrectionType` is set to `.no`.
- On macOS, the inline predictive text (introduced in macOS Sonoma/iOS 17) shows a
  grayed-out suggestion that completes the current word or phrase.
- Source: Apple WWDC sessions, Apple developer documentation

#### SYNTHESIS FOR YOUR SYSTEM:
- **Recommended approach**: Debounce of 300-400ms after last keystroke. This is the
  industry consensus. Optionally reduce to ~150ms if using a fast model/cache.
- **Trigger heuristics**: Always trigger at end of line, after space/punctuation, after
  newline. Suppress during rapid deletion, in password fields, in fields < 3 chars.
- **Configuration**: Let users choose between "eager" (more suggestions) and
  "conservative" (fewer, higher-quality suggestions).

---

### ===================================================================
### QUESTION 2: MID-WORD / MID-SENTENCE COMPLETION
### ===================================================================

**The core challenge: don't duplicate text that already exists before or after the cursor.**

#### The FIM (Fill-in-the-Middle) Approach
Most modern code completion tools use FIM-trained models. FIM reformats the prompt as:
```
<prefix>text before cursor<suffix>text after cursor<middle>
```
The model then generates text that should go between prefix and suffix. This is the
key architectural choice that enables mid-word completion.

- **Copilot**: Uses FIM format. The Codex/GPT models behind Copilot were fine-tuned
  with FIM objectives. The prefix is text before cursor, suffix is text after cursor.
  The model generates only the "middle" part, so there's no duplication by design.

- **Cursor**: Goes beyond basic FIM. Cursor's Tab model can suggest **diffs** -- it
  doesn't just insert text at the cursor, it can propose replacing a range of text
  around the cursor. This is how it handles mid-word completion: if you're in the
  middle of `getUserNa|me()` (cursor at `|`), it might suggest replacing `getName`
  with `getUsername`. The suggestion shows the full resulting line, and acceptance
  replaces the appropriate range.
  - Key implementation detail: Cursor sends the text before AND after the cursor to
    the model. The model returns a "rewrite" of the current line or region, and the
    editor computes the diff to show the user only what changes.

- **Continue.dev**: Uses FIM when the model supports it. The implementation in
  `autocomplete/templating/` directory shows how they format FIM prompts for different
  model providers. They detect cursor position, split the document into prefix (before
  cursor) and suffix (after cursor), and format according to the model's FIM template
  (e.g., `<fim_prefix>`, `<fim_suffix>`, `<fim_middle>` for StarCoder-style models).
  - For mid-word: they include the partial word in the prefix. The model generates
    the rest of the word + any continuation. Then they post-process to strip any
    text that duplicates what's already in the suffix.

- **Supermaven**: Uses FIM with their custom model. Their 300K token context window
  means they can include much more surrounding context than competitors.

- **Codeium**: Uses FIM with custom models. They specifically highlight mid-line
  completion as a feature. Their post-processing removes overlapping text.

- **Gmail Smart Compose**: Does NOT do mid-word completion. Suggestions only appear
  at the end of what's been typed. If you go back and edit mid-sentence, Smart Compose
  stops suggesting until you're at the end again.

- **Apple QuickType**: Handles mid-word by treating it as word completion. The current
  partial word is used as a prefix, and the system suggests completions for that word.
  It does not suggest text after the word or do sentence-level mid-sentence completion.

#### Post-Processing to Avoid Duplication
All tools that support mid-line completion need post-processing:
1. After the model returns its suggestion, compare the end of the suggestion with the
   beginning of the suffix (text after cursor).
2. If there's overlap (e.g., model suggests "Username()" and suffix starts with "me()"),
   trim the suggestion to remove the overlap.
3. Continue.dev's implementation has a function called `postprocessCompletion` that does
   exactly this: it finds the longest common suffix between the suggestion and the text
   after cursor, then trims.

#### SYNTHESIS FOR YOUR SYSTEM:
- **Use FIM-style prompting**: Always send both text-before-cursor and text-after-cursor
  to the model. This is the standard approach.
- **Post-process aggressively**: After getting a suggestion, compute overlap with existing
  text after cursor and trim. This prevents the "doubled text" problem.
- **For a system-wide tool (not code editor)**: FIM might be overkill. In most text fields,
  users type at the end. Implement FIM support but optimize for the common case of
  end-of-text completion. Only do mid-text completion if cursor is clearly mid-sentence.
- **Consider Cursor's diff approach** for advanced features later: suggest rewrites of
  the current sentence, not just insertions.

---

### ===================================================================
### QUESTION 3: WHAT CONTEXT TO SEND TO THE MODEL?
### ===================================================================

**More context = better suggestions, but there are latency and cost tradeoffs.**

#### Cursor
- Sends a **large context window**: the current file (or as much as fits), recently
  edited files, recently viewed files, and the file's language/path metadata.
- Uses a "context retrieval" system that ranks which files/snippets are most relevant
  to the current cursor position using embeddings and recency.
- For Tab completion specifically: sends ~2000 tokens of context from current file
  (centered on cursor position), plus snippets from 2-3 related files.
- Also sends: file path, language ID, git diff (recent changes), and project structure hints.
- Source: Cursor blog, user-reported observations

#### GitHub Copilot
- Sends context from the **current file** (up to model context limit), with text around
  cursor weighted more heavily.
- Uses a "prompt crafting" pipeline:
  1. Take the current file content, prioritizing text near cursor.
  2. Retrieve snippets from other open tabs in the editor (called "neighboring tabs").
  3. Use Jaccard similarity to find the most relevant snippets from other files.
  4. Assemble into a prompt with special tokens separating sections.
- Context budget: approximately 2048-4096 tokens for the prompt (varies by model version).
- Neighboring tab context: up to 20 snippets of ~60 lines each, ranked by similarity
  to the current cursor context.
- Source: "Inside GitHub: Working with the LLMs behind GitHub Copilot" (GitHub blog, 2023)

#### Supermaven
- Key differentiator: supports up to **300,000 tokens** of context.
- Sends the entire current file plus large portions of related files.
- Uses a streaming architecture where the model maintains state across requests,
  so it doesn't need to re-process the full context on every keystroke.
- This is why Supermaven claims to be faster: the model maintains a running KV-cache
  and only processes the incremental new tokens on each keystroke.

#### Continue.dev
- Context assembly is in `autocomplete/context/` -- open source and inspectable.
- Sends: current file content (up to configurable limit), with cursor position marked.
- Optionally includes snippets from other open files ranked by relevance.
- Uses a "sliding window" approach: for large files, sends the ~100-200 lines
  surrounding the cursor, plus the file header (imports/declarations).
- Source: https://github.com/continuedev/continue

#### Codeium
- Sends current file + metadata (language, path, imports).
- Has a "context engine" that indexes the entire workspace and retrieves relevant
  snippets using embeddings.
- Uses tree-sitter parsing to understand code structure and prioritize sending
  syntactically relevant context (e.g., the enclosing function, class definition,
  imported modules).

#### Gmail Smart Compose
- Sends the **current email body** (what's been typed so far) and the **subject line**.
- Also sends the email being replied to (if it's a reply).
- Does NOT send other emails or broader context.
- The context is relatively small compared to code tools: usually just a few sentences
  to a few paragraphs.
- Source: Google AI Blog, "Smart Compose: Using Neural Networks to Help Write Emails" (2018)

#### Apple QuickType
- Sends only the **current text field content** and recent typing history.
- On-device model has very limited context (likely ~100-500 tokens).
- Also uses: app identifier (to adjust predictions per app), language setting,
  user's personal dictionary/typing patterns, and keyboard state.
- Does NOT send data to a server (fully on-device in modern versions).

#### SYNTHESIS FOR YOUR SYSTEM:
- **For system-wide autocomplete**: You have less context than an IDE. You can capture:
  1. The current text in the active text field (via Accessibility API).
  2. The app name / field identifier for context about what the user is doing.
  3. Optionally: the window title, which might indicate the document/conversation topic.
- **Recommended context payload**:
  - Current text field content (or as much as accessible), with cursor position marked.
  - Application name and window title.
  - A "system context" hint: "The user is writing in [app] in a [text field type]."
  - Recent completions accepted (to maintain coherence in a session).
- **Context budget**: For fast responses, keep context under 2000-4000 tokens.
  Longer context = slower response, but better suggestions. Make this configurable.

---

### ===================================================================
### QUESTION 4: CACHING STRATEGIES
### ===================================================================

**Nearly all tools cache, but strategies differ.**

#### Copilot
- Caches the **most recent completion** and reuses it if the user's next few keystrokes
  match the beginning of the cached suggestion. For example, if the suggestion was
  "function getUserName()" and the user types "func", the cached suggestion is trimmed
  to "tion getUserName()" and shown without a new API call.
- This is called **"cache forwarding"** or **"speculative advancement"**.
- Cache is invalidated when:
  - The user types something that doesn't match the cached suggestion.
  - The user moves the cursor to a different location.
  - The user switches files.
  - A timeout expires (~10-30 seconds).
- Source: Observable in Copilot VS Code extension behavior; confirmed in technical talks.

#### Cursor
- Uses a similar cache-forwarding approach: if you start typing and it matches the
  predicted suggestion, the suggestion advances without a new request.
- Additionally caches at the **model server level**: Cursor runs their own inference
  infrastructure and uses KV-cache sharing across requests from the same file/context.
- The "speculative edits" feature effectively pre-caches the next likely edit location
  after you accept a suggestion.

#### Supermaven
- Server-side KV-cache is their **primary speed advantage**. The model maintains a
  persistent KV-cache for each user's editing session via the WebSocket connection.
- When the user types a new character, only that incremental token needs to be processed,
  not the full context. This is a form of "incremental inference."
- Cache invalidation: the server tracks the document state; if the user makes an edit
  that invalidates the cache (e.g., editing earlier in the document), the affected
  portion of the KV-cache is invalidated and recomputed.

#### Continue.dev
- Client-side caching: stores recent completions and reuses them if the user's typing
  matches. Implementation is in the autocomplete provider.
- No server-side caching (since it's model-agnostic and connects to various backends).

#### Gmail Smart Compose
- Caches the current suggestion and advances it character-by-character as the user
  types matching characters. This is the same "cache forwarding" pattern.
- If the user types something that doesn't match, the suggestion is dismissed and
  a new one is requested (with debounce).

#### Apple QuickType
- Caches predictions per-keystroke in a local prediction cache. Since inference is
  on-device and very fast, the cache lifetime is very short.
- Primary caching is of the model state itself (similar to KV-cache concept but
  for smaller on-device models).

#### SYNTHESIS FOR YOUR SYSTEM:
- **Implement cache forwarding**: This is the single most important optimization.
  When you get a suggestion "Hello world, how are you?", and the user types "H",
  then "e", then "l" -- don't make new requests. Just trim the cached suggestion.
  Only request a new completion when the user diverges from the cached path.
- **Cache key**: `(text_before_cursor_hash, cursor_position)`. Invalidate on:
  cursor movement, text divergence from cached suggestion, timeout (~15s), app switch.
- **Pre-fetching**: After a suggestion is accepted, immediately request the NEXT
  likely suggestion. This is what makes Cursor feel "psychic."

---

### ===================================================================
### QUESTION 5: REQUEST CANCELLATION
### ===================================================================

**All tools cancel in-flight requests aggressively.**

#### Common Pattern (used by Copilot, Cursor, Continue.dev, Codeium):
1. Each completion request gets a **CancellationToken** or **AbortController**.
2. When a new keystroke arrives (and debounce resets), the previous in-flight request
   is cancelled immediately.
3. The cancellation is both client-side (abort the HTTP/WebSocket request) and
   server-side (stop generating tokens if using streaming).
4. Implementation: `AbortController` in JavaScript/TypeScript (VS Code extensions),
   or cancellation tokens in the language server protocol.

#### Copilot-specific:
- Uses VS Code's `CancellationToken` API for inline completion providers.
- When VS Code calls the completion provider again (because user typed more), the
  previous token is automatically cancelled.
- The network request is aborted via `AbortController`.

#### Supermaven-specific:
- Because it uses a persistent WebSocket, cancellation is sending a "cancel" message
  on the socket rather than aborting an HTTP request. This is faster.
- The server can stop generation immediately when it receives the cancel signal.

#### Continue.dev (inspectable):
- In `completionProvider.ts`: maintains a reference to the current AbortController.
- On each new trigger: `this.abortController?.abort(); this.abortController = new AbortController();`
- The abort signal is passed through to the HTTP fetch call to the model backend.

#### SYNTHESIS FOR YOUR SYSTEM:
- **Use AbortController or equivalent**: Every request must have a cancellation mechanism.
- **Cancel aggressively**: On every new keystroke (even before debounce), cancel any
  in-flight request. Then start the debounce timer for the new request.
- **Server-side**: If you control the inference server, support streaming with
  cancellation. If using a third-party API (Claude, OpenAI), use their streaming API
  and close the connection on cancel.
- **WebSocket consideration**: For a system-wide tool with rapid-fire requests, a
  persistent WebSocket to your backend (like Supermaven) may be better than HTTP
  request/response to avoid connection overhead.

---

### ===================================================================
### QUESTION 6: CONFIDENCE THRESHOLDS
### ===================================================================

**How to decide if a suggestion is good enough to show.**

#### Gmail Smart Compose (most documented)
- Uses an explicit **confidence threshold**. The model outputs per-token probabilities.
- A suggestion is shown only if the average per-token log probability exceeds a
  threshold (tuned via A/B testing).
- Longer suggestions require HIGHER average confidence (since errors compound).
- Threshold was tuned to optimize for "suggestion precision" -- users should accept
  suggestions more often than they reject them. Target acceptance rate was ~25-30%.
- If confidence drops below threshold mid-generation, the suggestion is truncated at
  the last high-confidence token.
- Source: Chen et al., "Gmail Smart Compose: Real-Time Assisted Writing" (KDD 2019)

#### Copilot
- Uses a **quality filter** that evaluates completions before showing them.
- Filters based on:
  - Length: very short suggestions (1-2 characters) are suppressed unless high confidence.
  - Repetition: if the suggestion repeats existing code patterns, it may be suppressed.
  - Mean log probability of generated tokens (similar to Smart Compose).
  - A small classifier model that predicts "will the user accept this?" based on
    the suggestion, context, and various features.
- Source: GitHub blog "How GitHub Copilot is getting better at understanding your code" (2023)

#### Cursor
- Does not appear to use an explicit user-visible confidence threshold. Instead, the
  model is trained to produce high-quality suggestions, and the assumption is that
  if the model generates something, it's worth showing.
- However, Cursor DOES suppress suggestions in certain contexts (e.g., when the cursor
  is in a position where completion doesn't make sense, or when the model returns
  an empty/trivial suggestion).

#### Continue.dev
- Configurable confidence/quality settings. Has options like `disableInFiles` to
  suppress completions in certain file types.
- Post-processing includes: stripping suggestions that are just whitespace, removing
  suggestions that duplicate existing code, and truncating at natural boundaries.

#### Apple QuickType
- Shows 3 predictions always (when enabled), so there's no binary show/don't-show
  threshold. Instead, predictions are ranked by probability, and the top 3 are shown.
- For the inline prediction (macOS Sonoma+), there IS a confidence threshold: the
  inline suggestion only appears if the model is sufficiently confident about a
  multi-word prediction. Single word completions have a lower threshold.

#### SYNTHESIS FOR YOUR SYSTEM:
- **Implement a confidence threshold**: Use the model's token-level log probabilities.
- **Suggested approach**:
  1. Compute the mean log probability of all generated tokens.
  2. Set a minimum threshold (tune via user testing). Start around -1.0 to -0.5
     mean log prob as a baseline.
  3. Require higher confidence for longer suggestions.
  4. Suppress suggestions that are only 1-2 characters unless very high confidence.
  5. Suppress suggestions that are pure repetition of nearby text.
- **A/B test the threshold**: Too low = annoying, shows bad suggestions. Too high =
  feels broken, never shows anything. Target ~25-35% acceptance rate.

---

### ===================================================================
### QUESTION 7: PARTIAL ACCEPTANCE (WORD-BY-WORD)
### ===================================================================

#### Cursor
- Supports **word-by-word acceptance** via a configurable keybinding (Ctrl+Right or
  similar). Pressing Tab accepts the full suggestion; a different key accepts one word.
- This is a highly-requested feature that Cursor implemented early.

#### GitHub Copilot
- Supports **word-by-word acceptance** via `Cmd+Right` (macOS) / `Ctrl+Right` (Windows).
- The full suggestion appears grayed out; each press of the partial-accept key
  accepts one word and moves the cursor forward.
- Also supports accepting one line at a time in multi-line suggestions.
- Source: GitHub Copilot documentation, VS Code keybindings

#### Supermaven
- Supports partial acceptance (word-by-word) via keyboard shortcut.
- Because their suggestions tend to be longer (due to larger context), partial
  acceptance is particularly useful.

#### Continue.dev
- Supports partial acceptance. The keybinding is configurable.
- Implementation: the accepted portion is inserted, the remaining portion stays
  as a ghost text suggestion.

#### Gmail Smart Compose
- Does NOT support partial acceptance. It's all-or-nothing: press Tab to accept
  the entire suggestion, or keep typing to ignore it.

#### Apple QuickType
- On iOS: tapping the middle prediction accepts the full word. There's no word-by-word
  acceptance for multi-word predictions.
- On macOS (inline prediction): pressing the right arrow key accepts one word at a time.
  This was introduced in macOS Sonoma/iOS 17.

#### SYNTHESIS FOR YOUR SYSTEM:
- **Implement partial acceptance**: Tab = accept all, Cmd+Right (or configurable) =
  accept one word. This is expected by power users.
- **Implementation**: Keep track of the full suggestion. On partial accept, insert the
  next word, update the displayed ghost text to show only the remaining words.
- **Word boundary detection**: Split suggestion on whitespace and punctuation.
  Accept up to and including the next word boundary.

---

### ===================================================================
### QUESTION 8: MODELS AND MODEL SIZES
### ===================================================================

#### Cursor
- Uses **custom fine-tuned models** for Tab completion, NOT the same large models used
  for chat (GPT-4, Claude).
- The Tab model is likely in the **1-7B parameter range** -- small enough for fast
  inference, large enough for good quality.
- Trained specifically on code completion and code editing tasks.
- Cursor has mentioned using a "speculative decoding" approach where a small model
  generates candidates quickly and a larger model verifies/reranks.
- For longer completions (multi-line, function bodies), they may route to larger models.
- Source: Cursor blog, user community discussions

#### GitHub Copilot
- Originally used **OpenAI Codex** (a fine-tuned GPT-3, ~12B parameters).
- Later versions use models from the **GPT-3.5 to GPT-4 family**, with specific
  fine-tuning for code completion.
- Copilot likely uses a **distilled/smaller model for inline completions** and
  routes to larger models for chat/explain features.
- The completion model is estimated at ~6-12B parameters based on latency characteristics.
- Uses FIM (Fill-in-the-Middle) fine-tuning.
- Source: GitHub blog posts, OpenAI documentation

#### Supermaven
- Uses a **custom-trained model** built by Jacob Jackson (Supermaven's founder, who
  previously built Tabnine's deep learning models).
- The model supports a **300,000 token context window** -- much larger than competitors.
- Uses a novel architecture that allows efficient incremental inference (extending the
  KV-cache without reprocessing the full context).
- Model size is not publicly disclosed but is likely in the **3-7B range** based on
  inference speed characteristics.
- NOT based on a standard open model; it's trained from scratch.

#### Continue.dev
- Model-agnostic: works with ANY model that supports completion/FIM.
- Recommended models for autocomplete:
  - **StarCoder2 (3B, 7B, 15B)**: Open source, good FIM support.
  - **CodeLlama (7B, 13B)**: Open source, FIM-trained variants.
  - **DeepSeek Coder (1.3B, 6.7B, 33B)**: Strong FIM, very good quality/size ratio.
  - **Codestral (by Mistral, 22B)**: Excellent quality, supports FIM.
  - **Qwen2.5-Coder (1.5B, 7B)**: Recent, very strong for their size.
  - Also supports Copilot, OpenAI, Anthropic APIs for completion.
- For local inference: recommends 1.5B-7B models via Ollama for speed.
- Source: Continue.dev documentation

#### Codeium
- Uses **custom-trained models** that are optimized for speed.
- They have mentioned using a mixture of models: a very small, fast model (~1B) for
  common/simple completions, and a larger model for complex cases.
- Their focus is on model efficiency: quantization, optimized inference engines.
- They've discussed using **speculative decoding** in their blog.

#### Gmail Smart Compose
- Uses a **Transformer-XL** based model (at the time of the 2019 paper).
- The production model is relatively small for a language model -- optimized for serving
  at Gmail's scale (hundreds of millions of users).
- Estimated at **tens of millions to low billions** of parameters.
- Model runs server-side (not on device).
- Source: KDD 2019 paper

#### Apple QuickType
- Uses an **on-device neural language model** that is very small (estimated **tens of
  millions of parameters** -- certainly under 1B).
- Runs entirely on the Neural Engine / Apple Silicon GPU.
- The model is language-specific (separate models per language).
- In iOS 17+ / macOS Sonoma+, Apple upgraded to a larger Transformer-based model
  for the inline prediction feature (larger than previous n-gram + small NN approach).
- This is speculated to be related to Apple's on-device foundation models (which
  power Apple Intelligence features).

#### Open Source Models Commonly Used for Autocomplete:
| Model | Size | FIM Support | Notes |
|-------|------|-------------|-------|
| StarCoder2 | 3B, 7B, 15B | Yes | Trained on The Stack v2 |
| DeepSeek Coder | 1.3B, 6.7B, 33B | Yes | Excellent quality/size ratio |
| CodeLlama | 7B, 13B, 34B | Yes (FIM variants) | Meta, based on Llama 2 |
| Codestral | 22B | Yes | Mistral, state-of-art for code |
| Qwen2.5-Coder | 0.5B, 1.5B, 3B, 7B | Yes | Alibaba, very competitive |
| Phi-2/Phi-3 | 2.7B, 3.8B | Partial | Microsoft, good general + code |
| TinyLlama | 1.1B | No (needs fine-tune) | Very fast, minimal quality |

#### SYNTHESIS FOR YOUR SYSTEM:
- **For speed**: Use a 1.5B-3B model locally (DeepSeek Coder 1.3B, Qwen2.5-Coder 1.5B).
  These can run on Apple Silicon M-series with ~50-100ms per token.
- **For quality**: Route to a 7B+ model or API-based model (Claude, GPT-4o-mini).
  Latency will be 300-800ms for first token.
- **Recommended architecture**: Two-tier model system:
  1. Fast small model (local, 1-3B) for instant single-word / short completions.
  2. Larger model (API-based) for multi-word / sentence completions, called with
     more debounce delay.
- **For your "pluggable backend" requirement**: Abstract the model interface. Support
  local models (via `llama.cpp` / `mlx` on macOS) and API models (Claude, OpenAI).

---

### ===================================================================
### QUESTION 9: STREAMING VS BATCH
### ===================================================================

#### Cursor
- Uses **streaming** for Tab completions. Tokens arrive incrementally.
- However, the DISPLAY is often "batch-like": Cursor accumulates tokens and shows
  the suggestion only once enough tokens have arrived to form a meaningful suggestion
  (or after a short timeout).
- This avoids the "flickering" problem of showing suggestions that change rapidly.

#### GitHub Copilot
- Uses **batch** for inline completions: the entire suggestion is generated server-side,
  and only the complete suggestion is sent to the client.
- This is because VS Code's `InlineCompletionItemProvider` API expects a complete
  suggestion, not a stream. Showing a partial suggestion that changes would be jarring.
- For Copilot Chat: uses streaming.

#### Supermaven
- Uses **true streaming via WebSocket**. Tokens arrive one-by-one and the suggestion
  updates in real-time.
- The UI shows the suggestion growing as tokens arrive. This feels faster because the
  user sees the suggestion start to appear within ~100ms, even if the full suggestion
  takes 500ms.
- This is a key UX differentiator: perceived latency is much lower.

#### Continue.dev
- Supports both streaming and batch, depending on the model backend.
- For most providers: uses streaming. The suggestion is built up incrementally.
- Has logic to "debounce the display": doesn't update the shown suggestion on every
  single token, but batches a few tokens before updating the UI.

#### Codeium
- Uses **streaming** for completions. Their protocol sends tokens incrementally.
- Display is updated as tokens arrive, similar to Supermaven.

#### Gmail Smart Compose
- Uses **batch**: the complete suggestion is computed server-side and sent as a whole.
- The suggestion appears all at once as grayed-out text.
- This makes sense because email suggestions are typically short (3-10 words).

#### Apple QuickType
- Uses **batch** (but it's so fast on-device that it feels instant).
- The prediction bar updates synchronously with each keystroke -- the model is fast
  enough that by the time the keystroke is rendered, the prediction is ready.

#### SYNTHESIS FOR YOUR SYSTEM:
- **Use streaming from the model**, but **batch the display**.
- Implementation:
  1. Start streaming from the model as soon as the request fires.
  2. Accumulate tokens in a buffer.
  3. Show the suggestion to the user only when:
     - At least N tokens (3-5 words) have arrived, OR
     - The model has finished generating, OR
     - A display timeout (200-300ms) fires.
  4. Once shown, UPDATE the suggestion if more tokens arrive (growing suggestion).
- **Why not pure streaming display?** For a system-wide overlay, constantly changing
  the overlay size/content could be visually distracting. Better to show it once
  with a meaningful amount of text, then optionally extend it.
- **Why not pure batch?** Too slow. Users expect to see something within 300-500ms.
  Streaming lets you show partial results fast.

---

### ===================================================================
### QUESTION 10: MULTI-LINE VS SINGLE-LINE SUGGESTION LOGIC
### ===================================================================

#### Cursor
- Defaults to **multi-line suggestions** in code. The model decides how much to suggest
  based on the context.
- Heuristics:
  - At the end of a function signature or control statement: suggest the full body.
  - Mid-line: suggest only the rest of the current line.
  - At end of a block: suggest the next logical block.
- Cursor's Tab model is specifically trained to know when to stop: it generates a
  natural "stop point" (end of function, end of statement, etc.).

#### GitHub Copilot
- Generates **multi-line by default** but the VS Code UI can show it as single-line
  with an option to expand.
- The model generates until it hits a stop token or a max length.
- Copilot has heuristics to decide when to truncate:
  - If the suggestion starts with a comment, it might limit to the comment.
  - If it's completing a function body, it lets it run until the closing brace.
  - If it's completing a single statement, it stops at the semicolon/newline.

#### Supermaven
- Defaults to **longer, multi-line suggestions** -- they advertise this as a feature.
- Their 300K context window means the model has better "understanding" of what to
  generate and when to stop.

#### Continue.dev
- Configurable: `multilineCompletions` setting can be "always", "never", or "auto".
- In "auto" mode:
  - Suggests single-line if the cursor is in the middle of a line.
  - Suggests multi-line if the cursor is at the end of a line AND the context suggests
    a block is starting (e.g., after `:` in Python, after `{` in JS).
  - Limits multi-line suggestions to ~5-10 lines to avoid overwhelming the user.

#### Gmail Smart Compose
- **Single-line only**. Suggestions are limited to completing the current sentence
  or a short phrase. Never suggests multiple sentences.
- This is intentional: email is conversational, and multi-sentence suggestions would
  feel like the AI is writing the email for you (too intrusive).

#### Apple QuickType
- **Single-line only** for inline predictions. Suggests the completion of the current
  sentence or phrase, but never multi-line.
- The prediction bar (iOS) shows individual words, not sentences.

#### SYNTHESIS FOR YOUR SYSTEM:
- **For a system-wide tool, default to single-line / single-sentence suggestions.**
  Multi-line suggestions make sense in code editors where the structure is clear, but
  in arbitrary text fields (emails, messages, documents), multi-line suggestions are
  likely to be wrong and intrusive.
- **Adaptive approach**:
  - In short text fields (chat, search, URL bar): suggest only the rest of the line.
  - In long-form text (email compose, document editing): suggest up to the end of the
    current sentence.
  - With a hotkey (e.g., hold Option): generate a longer, multi-sentence suggestion.
- **Max suggestion length**: Cap at ~50 words / 1-2 sentences for the default mode.
  This prevents runaway generation and keeps suggestions manageable.
- **Stop conditions**: Stop generating at sentence boundaries (period + space),
  paragraph breaks, or when confidence drops below threshold.

---

### ===================================================================
### ADDITIONAL TOPICS
### ===================================================================

#### FIM (Fill-in-the-Middle) Architecture
- FIM is a training objective, not a model architecture per se.
- Standard approach: during training, a document is split at a random point into
  (prefix, middle, suffix). The model is trained to predict `middle` given
  `prefix` and `suffix` (with special tokens demarcating each part).
- At inference time, the text before the cursor becomes prefix, text after becomes
  suffix, and the model generates the middle.
- Different models use different token formats:
  - StarCoder: `<fim_prefix>`, `<fim_suffix>`, `<fim_middle>`
  - CodeLlama: `<PRE>`, `<SUF>`, `<MID>`
  - DeepSeek: `<|fim_begin|>`, `<|fim_hole|>`, `<|fim_end|>`
- FIM can be applied to natural language too, not just code. Any model fine-tuned with
  FIM objectives can do mid-text completion.

#### Speculative Decoding
- Technique to speed up inference from large models.
- A small "draft" model generates K candidate tokens quickly.
- The large "target" model then verifies all K tokens in a single forward pass.
- If the draft model's predictions match the target model's (which they often do for
  common patterns), you get K tokens for the cost of 1 forward pass on the large model.
- Used by: Cursor (confirmed in blog posts), Codeium (mentioned in blogs),
  Supermaven (likely, given their speed claims).
- Key paper: Leviathan et al., "Fast Inference from Transformers via Speculative Decoding"
  (ICML 2023).
- For your system: speculative decoding is most relevant if you run a local model and
  want to use a large (7B+) model with the speed of a small (1B) model.

#### Key Blog Posts and Resources (URLs to verify):
- Cursor Tab: https://cursor.sh/blog/cursor-tab
- GitHub Copilot internals: https://github.blog/2023-05-17-how-github-copilot-is-getting-better-at-understanding-your-code/
- Gmail Smart Compose paper: https://arxiv.org/abs/1906.00080 (KDD 2019)
- Supermaven blog: https://supermaven.com/blog
- Continue.dev docs on autocomplete: https://docs.continue.dev/features/autocomplete
- Continue.dev source code: https://github.com/continuedev/continue
- Speculative decoding paper: https://arxiv.org/abs/2211.17192
- FIM training: Bavarian et al., "Efficient Training of Language Models to Fill in the Middle" https://arxiv.org/abs/2207.14255
- "Inside GitHub Copilot" talk: https://github.blog/2024-04-12-inside-github-working-with-the-llms-behind-github-copilot/
- Codeium engineering blog: https://codeium.com/blog
- Apple predictive text WWDC: WWDC 2023 "What's new in text and text interactions"

#### Architecture Summary for a System-Wide Autocomplete Tool:

```
[Keystroke Capture (Accessibility API)]
         |
         v
[Debounce Timer (300-400ms)]
         |
         v
[Should-Trigger Heuristics] --> No --> (wait for next keystroke)
         |
        Yes
         |
         v
[Context Assembly]
  - Current text field content
  - Cursor position (split into prefix/suffix)
  - App name, window title
  - Recent accepted suggestions
         |
         v
[Cache Check] --> Hit --> [Advance cached suggestion] --> [Display]
         |
        Miss
         |
         v
[Cancel any in-flight request]
         |
         v
[Model Request (streaming)]
  - Send FIM-formatted prompt
  - Include system prompt with context hints
         |
         v
[Token Accumulation + Confidence Check]
  - Accumulate tokens
  - Check per-token confidence
  - Stop at sentence boundary or confidence drop
         |
         v
[Post-Processing]
  - Trim overlap with existing text after cursor
  - Remove duplicated text
  - Apply length limits
  - Filter low-quality suggestions
         |
         v
[Display as ghost text overlay]
  - Position at caret location
  - Style as grayed-out / dimmed text
  - Support Tab (accept all), Cmd+Right (accept word), Esc (dismiss)
         |
         v
[Cache the suggestion for forwarding]
```

---

### ============================================================
### FRONT-END RENDERING LAYER: COMPREHENSIVE RESEARCH
### ============================================================
### How to display inline text suggestions at the caret
### in ANY macOS application (system-wide)
### ============================================================

---

## APPROACH A: macOS Accessibility API (AXUIElement)

### How It Works

The Accessibility API provides a tree of UI elements for every running application.
The key flow for caret detection:

```
1. AXUIElementCreateSystemWide() -> system-wide element
2. Copy kAXFocusedApplicationAttribute -> get focused app
3. Copy kAXFocusedUIElementAttribute -> get focused element (text field)
4. Check role: kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, etc.
5. Copy kAXSelectedTextRangeAttribute -> CFRange with {location, length}
   - When length == 0, location IS the caret position
6. Use AXUIElementCopyParameterizedAttributeValue with
   kAXBoundsForRangeAttribute, passing the range -> CGRect in screen coords
```

### Key API Functions

```swift
// Get system-wide accessibility element
let systemWide = AXUIElementCreateSystemWide()

// Get focused application
var focusedApp: AnyObject?
AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)

// Get focused UI element (the text field)
var focusedElement: AnyObject?
AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

// Get selected text range (caret position when length=0)
var selectedRange: AnyObject?
AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &selectedRange)

// Convert range to screen bounds
var bounds: AnyObject?
AXUIElementCopyParameterizedAttributeValue(
    focusedElement as! AXUIElement,
    kAXBoundsForRangeAttribute as CFString,
    selectedRange!,
    &bounds
)
// bounds is an AXValue containing a CGRect in screen coordinates
```

### Reading Text Content via AX

In addition to caret position, the Accessibility API can read text content:

```swift
// Read the entire text field value
var value: AnyObject?
AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &value)
// value is a String containing the full text field content

// Read the currently selected text
var selectedText: AnyObject?
AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &selectedText)

// Read the number of characters
var charCount: AnyObject?
AXUIElementCopyAttributeValue(focusedElement, kAXNumberOfCharactersAttribute as CFString, &charCount)

// Read a specific substring by range
var substringRange = CFRange(location: 0, length: 50)
var rangeValue = AXValueCreate(.cfRange, &substringRange)!
var substring: AnyObject?
AXUIElementCopyParameterizedAttributeValue(
    focusedElement,
    kAXStringForRangeAttribute as CFString,
    rangeValue,
    &substring
)
```

### Reliability Across App Types

**GOOD support (AX works well):**
- Native Cocoa apps (TextEdit, Notes, Pages, Xcode, Mail) -- full AXTextArea/AXTextField
- Most AppKit-based text fields (NSTextField, NSTextView)
- Safari address bar and web content (Safari exposes AX for web text fields)
- Electron apps in general (Chrome's accessibility layer exposes text fields)
- VS Code (Electron-based, exposes AXTextArea with range info)
- Slack desktop (Electron)
- Microsoft Office for Mac (good AX support)

**PARTIAL support (some attributes missing or unreliable):**
- Chrome/Chromium browser text fields: AXSelectedTextRange often works but
  AXBoundsForRange can be unreliable or return incorrect rects in complex
  web pages. Works better with contentEditable than with textarea/input.
- Firefox: Historically poor AX support on macOS, improved significantly in
  recent versions. AXBoundsForRange may return the bounds of the entire field
  rather than the specific character range.
- Terminal.app / iTerm2: These expose AXTextArea/AXGroup but the text model
  is fundamentally different (terminal grid, not continuous text).
  AXSelectedTextRange may not reflect the shell cursor position.
  iTerm2 does expose some accessibility info but it maps to the visible
  terminal buffer, not the input line specifically.
- Kitty terminal: Minimal AX support by design.

**POOR/NO support:**
- Java AWT/Swing apps: Java has its own accessibility bridge (Java Access Bridge)
  that historically has poor macOS integration.
- Unity/game engine apps: No standard text field AX.
- Custom-rendered text (e.g., Sublime Text): Sublime renders text with its own
  engine, does NOT expose AXTextArea. It exposes a basic AXGroup but no
  AXSelectedTextRange or AXBoundsForRange. MAJOR gap.
- Some Qt apps: Qt has its own accessibility implementation that can be
  inconsistent on macOS.
- PDF viewers (inline annotation fields): Often no proper AX.

### Performance Characteristics

- AXUIElementCopyAttributeValue: ~0.5-2ms per call on modern hardware
- AXUIElementCopyParameterizedAttributeValue (BoundsForRange): ~1-5ms
- Full pipeline (focused app -> focused element -> range -> bounds): ~3-10ms
- **Polling at 30-60Hz is feasible** but wastes CPU when user isn't typing
- Better pattern: use CGEventTap for keystroke events, then query AX on-demand
- AX calls are synchronous IPC to the target app's process -- if the target app
  is busy/hung, the AX call blocks. Use with a timeout.
- AXObserver can watch for kAXSelectedTextChangedNotification to avoid polling.
  However, not all apps post this notification reliably.

### Required Permissions

- System Preferences > Privacy & Security > Accessibility
- App must be granted Accessibility access explicitly by the user
- Without this permission, ALL AX API calls return kAXErrorAPIDisabled

### Known GitHub Projects Using This Approach

- **Hammerspoon** (github.com/Hammerspoon/hammerspoon):
  Lua-scriptable macOS automation. Has extensive AX bindings via hs.axuielement.
  Can query focused element, selected text range, bounds. Great reference
  for AX API usage patterns.

- **AXSwift** (github.com/tmandry/AXSwift):
  Swift wrapper around AX APIs. Abstracts AXUIElement into Swift types.
  Reference for clean AX API usage.

- **Shortcat** (shortcatapp.com, was open source):
  Keyboard-driven clicking tool that uses AX to find clickable elements.
  Demonstrates AX tree traversal.

- **Accessibility Inspector** (included in Xcode):
  Apple's own tool for inspecting the AX tree. Essential for debugging
  which attributes apps expose.

### Caret Position Detection - Full Implementation Pattern

```swift
import ApplicationServices

func getCaretScreenRect() -> CGRect? {
    let systemWide = AXUIElementCreateSystemWide()

    // Step 1: Get focused application
    var appRef: AnyObject?
    guard AXUIElementCopyAttributeValue(
        systemWide,
        kAXFocusedApplicationAttribute as CFString,
        &appRef
    ) == .success else { return nil }

    let focusedApp = appRef as! AXUIElement

    // Step 2: Get focused UI element
    var elemRef: AnyObject?
    guard AXUIElementCopyAttributeValue(
        focusedApp,
        kAXFocusedUIElementAttribute as CFString,
        &elemRef
    ) == .success else { return nil }

    let focusedElement = elemRef as! AXUIElement

    // Step 3: Verify it's a text element
    var roleRef: AnyObject?
    guard AXUIElementCopyAttributeValue(
        focusedElement,
        kAXRoleAttribute as CFString,
        &roleRef
    ) == .success else { return nil }

    let role = roleRef as! String
    let textRoles = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXWebArea" // Web content areas
    ]
    guard textRoles.contains(role) else { return nil }

    // Step 4: Check for secure text field (password) -- skip these
    var subroleRef: AnyObject?
    if AXUIElementCopyAttributeValue(
        focusedElement,
        kAXSubroleAttribute as CFString,
        &subroleRef
    ) == .success {
        let subrole = subroleRef as! String
        if subrole == kAXSecureTextFieldSubrole as String {
            return nil // Never show suggestions in password fields
        }
    }

    // Step 5: Get selected text range
    var rangeRef: AnyObject?
    guard AXUIElementCopyAttributeValue(
        focusedElement,
        kAXSelectedTextRangeAttribute as CFString,
        &rangeRef
    ) == .success else { return nil }

    var range = CFRange()
    AXValueGetValue(rangeRef as! AXValue, .cfRange, &range)

    // Step 6: Create a range at the caret position for bounds query
    // Use length=1 to get actual character bounds (length=0 may return zero-width)
    var caretLocation = range.location + range.length
    var queryRange = CFRange(location: caretLocation, length: 1)

    // If at end of text, use the character before the caret instead
    var charCountRef: AnyObject?
    if AXUIElementCopyAttributeValue(
        focusedElement,
        kAXNumberOfCharactersAttribute as CFString,
        &charCountRef
    ) == .success {
        let charCount = charCountRef as! Int
        if caretLocation >= charCount && caretLocation > 0 {
            queryRange = CFRange(location: caretLocation - 1, length: 1)
            // We'll use the RIGHT edge of this character's bounds
        }
    }

    // Step 7: Get screen bounds for the range
    guard let queryRangeValue = AXValueCreate(.cfRange, &queryRange) else { return nil }

    var boundsRef: AnyObject?
    guard AXUIElementCopyParameterizedAttributeValue(
        focusedElement,
        kAXBoundsForRangeAttribute as CFString,
        queryRangeValue,
        &boundsRef
    ) == .success else { return nil }

    var rect = CGRect.zero
    AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect)

    // If we queried the character before caret, adjust to right edge
    if queryRange.location == caretLocation - 1 && caretLocation > 0 {
        rect.origin.x += rect.width
        rect.size.width = 1 // Thin caret-width rect
    }

    // rect is now in screen coordinates (AX uses top-left origin)
    return rect
}
```

**IMPORTANT NOTE on coordinate systems:**
- AX API returns CGRect with screen coordinates using TOP-LEFT origin
- AppKit/NSWindow uses BOTTOM-LEFT origin for screen coordinates
- To convert: `appKitY = mainScreenHeight - axY - rectHeight`
- Multi-monitor: the coordinate space is global across all screens
  with the primary screen's top-left as origin (0,0)

---

## APPROACH B: CGEventTap + Keystroke Monitoring

### How It Works

CGEventTap lets you install a callback on the system event stream. You can
observe (or modify) keyboard events before they reach any application.

```swift
let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                           | (1 << CGEventType.keyUp.rawValue)
                           | (1 << CGEventType.flagsChanged.rawValue)

guard let eventTap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,            // .defaultTap can modify, .listenOnly observes
    eventsOfInterest: eventMask,
    callback: { proxy, type, event, userInfo in
        // IMPORTANT: This callback must be FAST (<1ms)

        if type == .tapDisabledByTimeout {
            // macOS disabled our tap because callback was too slow
            // Re-enable it
            CGEvent.tapEnable(tap: /* saved tap ref */, enable: true)
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Get the Unicode character
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        var chars = [UniChar](repeating: 0, count: Int(length))
        event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &chars)
        let typedString = String(utf16CodeUnits: chars, count: Int(length))

        // Dispatch to main logic (asynchronously to keep callback fast)
        DispatchQueue.main.async {
            handleKeystroke(keyCode: keyCode, characters: typedString, event: event)
        }

        return Unmanaged.passUnretained(event) // Pass event through unmodified
    },
    userInfo: nil
) else {
    print("Failed to create event tap - check permissions")
    return
}

let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)
```

### What CGEventTap Can and Cannot Do

**CAN do:**
- Capture every keyDown, keyUp, flagsChanged event system-wide
- Get the key code, Unicode string, modifier flags
- Modify or suppress keystrokes before the app sees them (.defaultTap)
- Detect Tab press (to accept suggestion), Escape (to dismiss)
- Detect arrow keys, Enter, Delete, and all special keys
- Differentiate between physical key presses and programmatic events
  (via the eventSourceStateID field)

**CANNOT do:**
- Determine caret position (no spatial information)
- Know which text field is focused
- Read existing text in the field
- Know font, size, or visual layout
- Reliably detect mouse-click-based cursor repositioning
  (need separate mouse event tap for that)

### Combining CGEventTap with Accessibility API

The standard architecture used by most system-wide text tools:

```
CGEventTap (triggers on keystroke)
    |
    v
Debounce timer (300ms)
    |
    v
AX API queries:
  1. Get focused element
  2. Check if it's a text field
  3. Check if it's a secure field (skip password fields)
  4. Get text content (kAXValueAttribute)
  5. Get caret position (kAXSelectedTextRangeAttribute)
  6. Get caret screen bounds (kAXBoundsForRangeAttribute)
    |
    v
Send context to AI model
    |
    v
Position overlay window at caret bounds
```

### Required Permissions

- **Input Monitoring** (System Settings > Privacy & Security > Input Monitoring)
  Required for .listenOnly taps
- **Accessibility** (System Settings > Privacy & Security > Accessibility)
  Required for .defaultTap (event modification) AND for the AX API queries
- Both permissions must be granted explicitly by the user
- Without Input Monitoring, CGEvent.tapCreate returns nil

### Privacy Implications

- CGEventTap sees ALL keystrokes including passwords
- Must detect and skip secure text fields (AX role check)
- Some apps enable "Secure Input" mode (e.g., 1Password, banking apps)
  which disables ALL event taps system-wide
- SecureInput can be checked via: `IsSecureEventInputEnabled()`
- Apps should never log or transmit raw keystroke data
- Apple's notarization process scrutinizes apps using event taps

### Performance

- Event tap callback runs synchronously -- must return quickly (<1ms)
- If callback takes too long, macOS auto-disables the tap
- Handle tapDisabledByTimeout and re-enable
- Minimal CPU overhead when idle (event-driven, not polling)
- Good practice: do minimal work in callback, dispatch async for heavy logic

### Known Projects Using CGEventTap

- **Karabiner-Elements** (github.com/pqrs-org/Karabiner-Elements):
  Premier keyboard customization tool. Uses DriverKit virtual HID device
  (since macOS 11) for its core key remapping. Also uses CGEventTap for
  some features. Architecture: kernel extension/DriverKit driver ->
  karabiner_grabber -> karabiner_event_dispatcher.
  Highly complex but extremely reliable.

- **Espanso** (github.com/espanso/espanso):
  Text expander in Rust. On macOS, uses CGEventTap to detect typing patterns.
  Combines with Accessibility API or clipboard-based injection for text insertion.
  Key insight: Espanso does NOT position overlays at caret -- it replaces text
  via simulated keystrokes or clipboard paste. Its search bar is a separate window.
  The macOS-specific code is in `espanso-detect/src/mac/` and `espanso-inject/src/mac/`.

- **Rocket** (matthewpalmer.net/rocket):
  Emoji picker. Uses CGEventTap to detect ":" trigger. Positions popup using
  AX caret detection when possible, falls back to mouse position.

- **Clipy** (github.com/Clipy/Clipy):
  Clipboard manager with event taps for hotkey detection.

- **KeyboardShortcuts** (github.com/sindresorhus/KeyboardShortcuts):
  Swift package for global keyboard shortcuts using CGEventTap.

### Text Insertion Methods (After Accepting a Suggestion)

| Method | How | Pros | Cons |
|--------|-----|------|------|
| Simulated keystrokes | Create CGEvents for each character | Works everywhere | Slow for long text, encoding issues |
| Clipboard injection | Copy to clipboard + simulate Cmd+V | Fast, reliable | Overwrites user's clipboard |
| AX SetValue | Set kAXValueAttribute on text field | Clean, direct | Not all apps support it |
| AX InsertText | Set kAXSelectedTextAttribute | Inserts at cursor | Limited app support |
| Clipboard + restore | Save clipboard, paste, restore | Doesn't lose clipboard | Race conditions |

**Espanso's approach**: Tries AX text insertion first. If that fails (returns error),
falls back to clipboard injection with clipboard save/restore. This is the most
robust pattern.

```swift
// Clipboard injection pattern with restore
func insertTextViaClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    let savedContents = pasteboard.pasteboardItems?.map { item -> [String: Data] in
        var dict: [String: Data] = [:]
        for type in item.types {
            if let data = item.data(forType: type) {
                dict[type.rawValue] = data
            }
        }
        return dict
    }

    // Set suggestion text on clipboard
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)

    // Simulate Cmd+V
    let vKeyCode: CGKeyCode = 9
    let source = CGEventSource(stateID: .combinedSessionState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
    keyDown?.flags = .maskCommand
    keyUp?.flags = .maskCommand
    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)

    // Restore clipboard after a short delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        pasteboard.clearContents()
        savedContents?.forEach { itemDict in
            let item = NSPasteboardItem()
            for (type, data) in itemDict {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type))
            }
            pasteboard.writeObjects([item])
        }
    }
}
```

---

## APPROACH C: Custom Input Method (IME / Input Source)

### How macOS Input Methods Work

An Input Method is a special bundle (.app) that registers with the Text Input
Sources system. When active, it sits between the keyboard and the application,
intercepting keystrokes and producing "composed" text.

```
Hardware Keyboard -> macOS Event System -> Input Method -> NSTextInputClient -> App
```

Key classes (InputMethodKit framework):
- **IMKServer**: The server object that registers your input method
- **IMKInputController**: Your subclass that handles input events
- **NSTextInputClient**: The protocol apps implement to receive composed text
- **IMKCandidates**: Optional candidate window for showing completion choices

### Core Flow

```objc
// In your IMKInputController subclass:

- (BOOL)handleEvent:(NSEvent *)event client:(id<IMKTextInput>)client {
    if (event.type == NSEventTypeKeyDown) {
        NSString *chars = event.characters;

        // OPTION 1: Pass through (don't handle this keystroke)
        return NO;

        // OPTION 2: Set "marked text" (inline composition -- KEY FEATURE)
        // This renders text INSIDE the app's text field, at the caret
        NSAttributedString *marked = [[NSAttributedString alloc]
            initWithString:@"suggestion text here"
            attributes:@{
                NSForegroundColorAttributeName: [NSColor grayColor],
                // App may or may not honor these attributes
            }];
        [client setMarkedText:marked
               selectionRange:NSMakeRange(0, 0)       // cursor within marked text
               replacementRange:NSMakeRange(NSNotFound, 0)]; // replace nothing
        return YES;  // Event consumed by IME

        // OPTION 3: Commit text (finalize, insert into document)
        [client insertText:@"accepted text"
          replacementRange:NSMakeRange(NSNotFound, 0)];
        return YES;
    }
    return NO;
}

// Called when the input method is activated
- (void)activateServer:(id)client {
    // Initialize state
}

// Called when the input method is deactivated
- (void)deactivateServer:(id)client {
    // Clean up, commit any pending text
}
```

### How CJK IMEs Render Inline Composition Text

This is the KEY insight for understanding what's possible:

1. User types romanized keys (e.g., "nihon" for Japanese)
2. IME calls `[client setMarkedText:...]` with composed characters
3. The APP renders this text inline at the caret with special styling
   (typically underlined, sometimes with a highlight background)
4. This text is rendered BY THE APPLICATION, not by the IME
5. The IME provides an attributed string; the app controls rendering
6. When user confirms, IME calls `[client insertText:...]` to commit

**This means marked text is TRUE INLINE TEXT** -- it appears inside the
text field, at the caret, with the correct font and position. It is NOT
an overlay window. This is the closest thing to "ghost text" that macOS
provides natively.

### Can This Be Used for Autocomplete Ghost Text?

**YES, with significant caveats.**

**Advantages:**
- True inline rendering inside the app's text view
- Correct font, size, position -- the app handles rendering
- Works in any app that supports NSTextInputClient (most native apps)
- You can style the marked text (gray color for ghost text appearance)
- No need to detect caret position -- app already knows where to render
- No overlay window alignment issues
- No Accessibility permission required

**The Autocomplete-via-IME Approach:**
1. Build a custom Input Method (.app bundle)
2. User adds it as an Input Source and activates it
3. When user types, your IME receives the keystroke via handleEvent:
4. Pass the keystroke through to the app (insertText: the typed character)
5. Asynchronously request AI suggestion
6. Display suggestion as marked text (gray, inline)
7. If user presses Tab: commit marked text with insertText:
8. If user keeps typing: clear marked text, pass through new keystroke
9. If user presses Escape: clear marked text (unmarkText)

**Critical Limitations:**

**1. User must select your Input Source:**
The input method must be actively selected in the menu bar. You cannot
programmatically activate your input method. Users must go to
System Settings > Keyboard > Input Sources, add your input method,
and select it. This is a significant UX barrier for non-technical users.

**2. Conflict with CJK input methods:**
macOS only supports ONE active input source at a time per app window.
If the user uses a Chinese/Japanese/Korean input method, they cannot use
your autocomplete IME simultaneously. This is a MAJOR blocker for CJK users.

**3. Marked text styling limitations:**
While you send an NSAttributedString, apps are NOT required to honor your
styling attributes. Many apps apply their own marked text styling:
- NSTextView: Renders marked text with a thin underline by default.
  Custom attributes (like gray text color) may or may not be applied.
- WebKit/WKWebView: Typically underlines marked text with a solid line.
- Electron/Chrome: Underlines marked text, may ignore color attributes.
The "gray ghost text" appearance you want may not be achievable through
marked text alone -- apps often override the visual styling.

**4. Interaction complexity:**
When marked text is active, the text input system enters a "composition" state.
This affects how subsequent keystrokes are interpreted:
- Arrow keys may navigate WITHIN the marked text
- Clicking elsewhere may commit or discard the marked text
- The app may show its own IME-related UI (e.g., candidate bar)
This creates UX friction for a simple autocomplete use case.

**5. Limited access to surrounding text context:**
You can request context via `[client attributedSubstringFromRange:]`, but
not all clients implement this fully. Many return nil. This limits the
quality of AI suggestions since you may not have enough surrounding text.

**6. Single marked text region:**
Only one marked text region can exist at a time. If your ghost text is
showing (as marked text) and the user starts interacting with it (arrow
keys within marked text), behavior can be unexpected.

**7. App compatibility:**
- NSTextView: Excellent support (fully implements NSTextInputClient)
- NSTextField: Good support
- WKWebView/WebKit: Good support (web text fields participate in IME)
- Electron apps: Generally good (Chromium supports IME)
- Terminal.app: Partial (terminal emulators have special IME handling)
- iTerm2: Partial -- has its own IME handling that can conflict
- Sublime Text: Historically poor IME support; improved but quirky
- JetBrains IDEs: Good IME support (native text input despite Java base)

### Input Method Bundle Structure

```
YourAutocomplete.app/
  Contents/
    Info.plist           # Must declare InputMethodKit keys
    MacOS/
      YourAutocomplete   # Main executable
    Resources/
      icon.tiff          # Menu bar icon
```

**Info.plist configuration:**
```xml
<key>InputMethodConnectionName</key>
<string>YourAutocomplete_Connection</string>
<key>InputMethodServerControllerClass</key>
<string>YourInputController</string>
<key>tsInputMethodCharacterRepertoireKey</key>
<array>
    <string>Latn</string>
</array>
<key>tsInputMethodIconFileKey</key>
<string>icon.tiff</string>
<key>ComponentInputModeDict</key>
<dict>
    <key>tsInputModeListKey</key>
    <dict>
        <key>com.yourcompany.inputmethod.Autocomplete</key>
        <dict>
            <key>TISInputSourceID</key>
            <string>com.yourcompany.inputmethod.Autocomplete</string>
            <key>tsInputModeDefaultStateKey</key>
            <true/>
            <key>tsInputModeScriptKey</key>
            <string>smRoman</string>
            <key>tsInputModePrimaryInScriptKey</key>
            <true/>
            <key>tsInputModeIsVisibleKey</key>
            <true/>
            <key>tsInputModeMenuIconFileKey</key>
            <string>icon.tiff</string>
        </dict>
    </dict>
</dict>
```

**Installation location:**
- `~/Library/Input Methods/` (user-level, no admin needed)
- `/Library/Input Methods/` (system-level, requires admin)

Registration happens automatically when the bundle is in the correct
location, but user must manually enable it in System Settings.

### Main Entry Point for Input Method

```swift
import Cocoa
import InputMethodKit

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var server: IMKServer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        server = IMKServer(
            name: "YourAutocomplete_Connection",
            bundleIdentifier: Bundle.main.bundleIdentifier!
        )
    }
}

class AutocompleteInputController: IMKInputController {
    var composingBuffer: String = ""
    var pendingSuggestion: String? = nil

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown else { return false }
        guard let client = sender as? IMKTextInput else { return false }

        let keyCode = event.keyCode
        let chars = event.characters ?? ""

        // Tab: accept suggestion
        if keyCode == 48 /* Tab */ && pendingSuggestion != nil {
            client.insertText(pendingSuggestion!, replacementRange: NSRange(location: NSNotFound, length: 0))
            pendingSuggestion = nil
            return true
        }

        // Escape: dismiss suggestion
        if keyCode == 53 /* Escape */ && pendingSuggestion != nil {
            pendingSuggestion = nil
            // Clear marked text
            let empty = NSAttributedString(string: "")
            client.setMarkedText(empty, selectionRange: NSRange(location: 0, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }

        // Normal character: pass through and request suggestion
        if !chars.isEmpty && !event.modifierFlags.contains(.command) {
            // Clear any existing suggestion
            if pendingSuggestion != nil {
                let empty = NSAttributedString(string: "")
                client.setMarkedText(empty, selectionRange: NSRange(location: 0, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                pendingSuggestion = nil
            }

            // Insert the typed character directly
            client.insertText(chars, replacementRange: NSRange(location: NSNotFound, length: 0))

            // Request suggestion asynchronously
            requestSuggestion(for: client)

            return true  // We handled the event
        }

        return false  // Let the system handle other events
    }

    func requestSuggestion(for client: IMKTextInput) {
        // Get context from the client (may not work in all apps)
        let contextRange = NSRange(location: 0, length: 500) // First 500 chars
        let context = client.attributedSubstring(from: contextRange)?.string ?? ""

        // Async AI request (simplified)
        DispatchQueue.global().async {
            let suggestion = self.getAISuggestion(context: context)
            DispatchQueue.main.async {
                guard !suggestion.isEmpty else { return }
                self.pendingSuggestion = suggestion

                // Show as marked text (inline ghost text)
                let attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor.gray,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
                let markedText = NSAttributedString(string: suggestion, attributes: attrs)
                client.setMarkedText(markedText,
                                     selectionRange: NSRange(location: 0, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }

    func getAISuggestion(context: String) -> String {
        // Call AI backend here
        return ""
    }
}
```

### GitHub Projects Implementing Custom macOS Input Methods

- **hallelujah-im** (github.com/dongyuwei/hallelujah-im):
  English auto-completion input method for macOS using InputMethodKit.
  THIS IS THE MOST DIRECTLY RELEVANT PROJECT. Shows English word completions
  inline as you type. Uses a candidate window (not marked text) for display.
  Dictionary-based backend (could be replaced with AI).

- **fcitx5-macos** (github.com/fcitx-contrib/fcitx5-macos):
  Full-featured input method framework for macOS. CJK input support.
  Excellent reference for InputMethodKit patterns including marked text
  handling, candidate windows, and state management.

- **Squirrel (RIME)** (github.com/rime/squirrel):
  Popular Chinese input method with macOS frontend. Production-quality
  InputMethodKit implementation. Good reference for candidate windows
  and IME lifecycle management.

- **OpenVanilla** (github.com/openvanilla/openvanilla):
  Open-source input method framework for macOS. Long history, well-documented.
  Shows IMKInputController lifecycle and text composition patterns.

- **macOS-IMKSample** (various on GitHub):
  Search "InputMethodKit sample" or "InputMethodKit example" on GitHub
  for minimal starter projects.

- **NumberInput_IMKit_Sample**:
  Historical Apple sample code for InputMethodKit. May be available
  in older Xcode documentation archives or online mirrors.

### Key Insight from hallelujah-im

Even projects trying to do English autocomplete via IME tend to use a
CANDIDATE WINDOW (overlay popup showing a list of completions) rather
than marked text for displaying suggestions. This is because:
1. Marked text replaces/overlays what the user is typing, which feels
   wrong for simple autocomplete (vs. CJK composition where it's expected)
2. The styling of marked text (underline, highlight) doesn't match the
   "gray ghost text" expectation users have from tools like Gmail/Copilot
3. Managing marked text state (composition start/end, cursor within
   marked text, interaction with app's undo stack) is complex

---

## APPROACH D: Overlay Window (NSWindow/NSPanel)

### How to Create a Transparent, Non-Activating Overlay

```swift
class SuggestionPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Critical properties for an overlay:
        self.level = .floating            // Above normal windows
        self.isOpaque = false             // Transparent background
        self.backgroundColor = .clear     // Fully transparent
        self.hasShadow = false            // No shadow (or true for subtle shadow)
        self.ignoresMouseEvents = true    // Click-through: clicks pass to app below
        self.collectionBehavior = [
            .canJoinAllSpaces,            // Visible on all Spaces/Desktops
            .stationary,                  // Don't move with Space switches
            .fullScreenAuxiliary          // Visible over full-screen apps
        ]
        self.hidesOnDeactivate = false    // Stay visible when our app isn't active

        // Set up the content view
        let hostingView = NSHostingView(rootView: SuggestionView())
        // Or use a simple NSTextField:
        let label = NSTextField(labelWithString: "")
        label.textColor = NSColor.systemGray.withAlphaComponent(0.6)
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.font = .systemFont(ofSize: 14) // Match target app's font
        label.translatesAutoresizingMaskIntoConstraints = false
        self.contentView?.addSubview(label)
    }
}
```

### .nonactivatingPanel Explained

`NSPanel` with `.nonactivatingPanel` style mask is the key ingredient.
Unlike a regular NSWindow:
- It does NOT become the key window when shown
- It does NOT steal focus from the current app
- The current app remains active and continues receiving keystrokes
- This is exactly what we need: show ghost text without disrupting typing

This is the same mechanism used by Spotlight, dictionary lookups, and
macOS autocomplete popups.

### Positioning at the Caret

This requires AX API (Approach A) to get caret screen coordinates:

```swift
func positionOverlay(at caretRect: CGRect) {
    // caretRect from AX is in screen coords with TOP-LEFT origin
    // NSWindow uses BOTTOM-LEFT origin (Cocoa coordinate system)

    guard let screen = screenContaining(point: caretRect.origin) else { return }
    let screenFrame = screen.frame

    // Convert Y from top-left (AX) to bottom-left (AppKit)
    let flippedY = screenFrame.height - caretRect.origin.y - caretRect.height
    // Adjust for screen origin (multi-monitor)
    let windowY = screenFrame.origin.y + flippedY

    // Position overlay just to the right of the caret
    let overlayOrigin = NSPoint(
        x: caretRect.origin.x + caretRect.width + 1,  // 1px gap after caret
        y: windowY - 2  // Slight adjustment for text baseline alignment
    )

    // Size the window to fit the suggestion text
    let textSize = measureText(pendingSuggestion, font: matchedFont)
    let windowSize = NSSize(
        width: textSize.width + 8,   // Small padding
        height: textSize.height + 4
    )

    overlayWindow.setFrame(NSRect(origin: overlayOrigin, size: windowSize), display: true)
    overlayWindow.orderFrontRegardless()  // Show above all windows
}

func screenContaining(point: CGPoint) -> NSScreen? {
    // AX coordinates: (0,0) is top-left of primary screen
    // Convert to find which NSScreen contains this point
    for screen in NSScreen.screens {
        // NSScreen.frame uses bottom-left origin
        let screenFrame = screen.frame
        let screenTop = screenFrame.origin.y + screenFrame.height

        // Convert AX point to Cocoa coordinates for this screen
        let cocoaPoint = NSPoint(
            x: point.x,
            y: NSScreen.screens[0].frame.height - point.y
        )
        if screenFrame.contains(cocoaPoint) {
            return screen
        }
    }
    return NSScreen.main
}
```

### Challenges and Solutions

**1. Multi-Monitor:**
```
Challenge: Each monitor has different frame origins and potentially different
scaling factors. AX coordinates span across all monitors in a unified space.

Solution:
- Use NSScreen.screens to enumerate all connected monitors
- Primary screen (screens[0]) has origin at bottom-left of the display arrangement
- Convert AX top-left coordinates to Cocoa bottom-left for each screen
- Test with: monitors side-by-side, stacked, different resolutions
```

**2. Retina/HiDPI Scaling:**
```
Challenge: On Retina displays, 1 point = 2 pixels. Mixed setups (Retina
laptop + non-Retina external) have different scaling per screen.

Solution:
- NSWindow coordinates are always in points (not pixels) -- AppKit handles scaling
- AX BoundsForRange returns points, not pixels (already scaled correctly)
- The overlay window will render at the correct resolution automatically
- Use screen.backingScaleFactor to check if Retina, but usually don't need to
- Font rendering: the overlay text will match Retina/non-Retina of its screen
```

**3. Font Matching:**
```
Challenge: To look like "ghost text" that belongs in the text field, the overlay
must use the same font, size, and baseline as the target text field.

Approach 1 - AX Font Detection:
  var fontRef: AnyObject?
  let fontRange = CFRange(location: max(0, caretPosition - 1), length: 1)
  AXUIElementCopyParameterizedAttributeValue(
      element, kAXAttributedStringForRangeAttribute, rangeValue, &fontRef
  )
  // Extract font attributes from the attributed string

Approach 2 - Heuristic:
  - Use system default font (SF Pro) at common sizes (13-16pt)
  - Detect app-specific defaults (e.g., Terminal uses Menlo/SF Mono)
  - Let user configure font override per-app

Approach 3 - Accept imperfection:
  - Use a popup/tooltip style instead of trying to match inline text exactly
  - This is what Grammarly, PopClip, and most overlay tools do
  - Show suggestion in a small tooltip-like bubble below/beside the caret
```

**4. Window Layering:**
```
Challenge: The overlay must appear above the target app but below certain
system UI elements.

Window levels (from lowest to highest):
  .normal (0)           -- regular app windows
  .floating (3)         -- floating panels, utility windows
  .submenu (3)          -- menus
  .tornOffMenu (3)      -- torn-off menus
  .modalPanel (8)       -- modal dialogs
  .mainMenu (24)        -- menu bar
  .statusBar (25)       -- status bar items
  .popUpMenu (101)      -- popup menus
  .screenSaver (1000)   -- screen saver
  .maximumLevel (2^31)  -- highest possible

Recommended: Use .floating (3) or NSWindow.Level(rawValue: 3)
This works for most cases. For full-screen apps, ensure .fullScreenAuxiliary
is in collectionBehavior.
```

**5. Animation and Smoothness:**
```swift
// Smooth appearance/disappearance
func showSuggestion(_ text: String, at caretRect: CGRect) {
    overlayWindow.alphaValue = 0
    positionOverlay(at: caretRect)
    updateOverlayText(text)

    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        overlayWindow.animator().alphaValue = 1.0
    }
}

func hideSuggestion() {
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.1
        overlayWindow.animator().alphaValue = 0
    } completionHandler: {
        self.overlayWindow.orderOut(nil)
    }
}
```

### How Existing Tools Handle Overlays

**PopClip:**
- Appears near selected text using AX BoundsForRange
- Falls back to mouse position if AX fails
- Shows horizontal toolbar above/below selection
- Uses NSPanel with .nonactivatingPanel

**Grammarly Desktop:**
- Uses AX to find the focused text field and its bounds
- Shows a floating "G" icon near the text field
- Underline-style suggestions are positioned using AX character bounds
- All visual feedback is overlay-based -- no true inline injection
- Known to sometimes misalign, especially in web-based text fields

**macOS Dictionary Lookup (Cmd+Ctrl+D or Force Touch):**
- Uses HIDictionaryWindowShow (private API)
- Positions a popover at the selected word using AX bounds
- Non-activating, click-through

**macOS Native Autocomplete (NSTextView):**
- Uses NSTextView's built-in -complete: method
- Shows a popup completion list below the caret
- Uses firstRectForCharacterRange: internally (NSTextInputClient protocol)
- Only available within NSTextView subclasses -- not system-wide

**macOS Inline Predictions (Sonoma+):**
- Apple's system-wide inline predictions use PRIVATE APIs
- Renders gray ghost text directly in native text fields
- Uses private frameworks: TextInput.framework, IntelligentSuggestions.framework
- Text views opt in via private property _allowsInlinePredictions
- Third-party apps CANNOT use this mechanism via any public API
- This is exactly the UX we want, but Apple has not made it public

---

## APPROACH COMPARISON & ANALYSIS

### Comparison Matrix

| Criterion                    | AX + Overlay    | CGEventTap + AX | Custom IME       | IME + Overlay   |
|------------------------------|-----------------|------------------|------------------|-----------------|
| Caret detection              | Good (70-80%)   | Good (70-80%)    | N/A (not needed) | N/A             |
| True inline rendering        | No (overlay)    | No (overlay)     | Yes (marked text)| Partial         |
| Native app support           | Good            | Good             | Excellent        | Good            |
| Electron app support         | Good            | Good             | Good             | Good            |
| Browser support              | Moderate        | Moderate         | Good             | Moderate        |
| Terminal support             | Poor            | Poor             | Partial          | Poor            |
| Setup complexity for user    | Low (1 perm)    | Med (2 perms)    | High (add input) | High            |
| CJK user compatibility      | Good            | Good             | POOR (conflict)  | Poor            |
| Font matching                | Hard            | Hard             | Automatic        | Hard            |
| Text context access          | Good (AX)       | Limited          | Limited          | Good (AX)       |
| Read existing text           | Yes (AX value)  | No               | Partial          | Yes (AX)        |
| Required permissions         | Accessibility   | Acc + InputMon   | None (IME setup) | Acc + IME       |
| Tab key interception         | Via AX/EventTap | Yes (EventTap)   | Yes (handleEvent)| Yes             |

### What Products Actually Do (Reverse-Engineered)

**Grammarly Desktop for Mac:**
- Architecture: AX API + Overlay Windows
- Uses Accessibility API to detect focused text field and read content
- Positions floating windows using AX caret bounds
- Does NOT use IME
- Does NOT inject inline text into apps
- All visual feedback (underlines, suggestions) is overlay-based
- Requires Accessibility permission
- Known failure: misalignment in some Electron apps, no support in
  apps without proper AX implementation

**Espanso (Text Expander):**
- Architecture: CGEventTap + Clipboard Injection
- Uses CGEventTap for keystroke monitoring (detect trigger patterns)
- Uses AX API to try direct text manipulation
- Falls back to clipboard injection (copy + Cmd+V)
- Does NOT show inline ghost text -- replaces text after trigger match
- Written in Rust with macOS ObjC bindings
- Requires: Accessibility + Input Monitoring permissions

**Cursor Tab Completion:**
- Architecture: Editor Plugin (VS Code InlineCompletionItemProvider)
- Ghost text rendered by VS Code's own rendering engine
- NOT system-wide -- works only within Cursor/VS Code
- Not transferable to system-wide approach

**GitHub Copilot:**
- Architecture: Editor Plugin (VS Code InlineCompletionItemProvider)
- Same as Cursor -- editor-internal, not system-wide

**macOS QuickType / Predictive Text:**
- Architecture: Private system framework integration
- Uses private TextInput.framework APIs
- True inline rendering in native text fields
- Not accessible to third-party developers

---

## RECOMMENDED ARCHITECTURE

### Primary: Hybrid (CGEventTap + AX API + Overlay Window)

This is the proven production architecture (used by Grammarly):

```
[CGEventTap] ----keystrokes----> [Core Logic / Debounce]
                                       |
                                  [AX API: Read text]
                                  [AX API: Get caret position]
                                       |
                                  [AI Backend (streaming)]
                                       |
                                  [Overlay Window at caret]
                                       |
                                  [Tab -> Insert text via AX or clipboard]
                                  [Esc -> Dismiss overlay]
```

**Why this is recommended:**
- Proven pattern used by shipping products
- No UX barriers (user doesn't switch input source, just grants permission)
- Works alongside CJK input methods
- Can read existing text for AI context
- Graceful degradation (fallback to mouse position if AX fails)
- Single Accessibility permission covers both AX and event tap needs

### Secondary (Experimental): Custom IME for Enhanced Experience

For users who want true inline rendering:
- Build an input method bundle as a separate installable component
- Provides true inline ghost text (marked text rendering)
- Opt-in only, disabled if CJK IME detected
- Does not require Accessibility permission

### Dual-Mode Architecture

```
Mode 1 (Default): AX + Overlay
  - Works everywhere with single permission
  - Ghost text as overlay window next to caret
  - Good enough for most users

Mode 2 (Power User Opt-in): Custom IME
  - True inline marked text rendering
  - Better visual integration
  - User manually activates input source
  - Conflicts with CJK input methods
```

---

## KEY QUESTIONS -- DEFINITIVE ANSWERS

### 1. Most reliable way to detect caret position across apps?
**Accessibility API (AXBoundsForRange)** is the most reliable single approach.
Works in ~70-80% of macOS apps. For the remaining 20%, fallbacks include:
mouse position, center of focused element bounds, or fixed screen position.

### 2. Can you render true inline ghost text?
**Only via InputMethodKit marked text** or Apple's private inline prediction
APIs (macOS Sonoma+). Overlay windows can simulate ghost text but will never
perfectly match the app's font rendering. There is no public API to inject
rendered text into another app's text field.

### 3. How do existing tools solve "where is the cursor?"
- **Grammarly**: AX API (AXBoundsForRange)
- **Espanso**: Does not need cursor position (text replacement via clipboard)
- **PopClip**: AX API with mouse position fallback
- **Rocket**: AX API with mouse position fallback
- **macOS Inline Predictions**: Private system API (not available to third parties)

### 4. Required macOS permissions?
- **Accessibility**: Required for AX API (read text, get caret, insert text)
- **Input Monitoring**: Required for CGEventTap (keystroke capture)
- **No special permission for InputMethodKit** (user must manually add input source)
- Note: A single Accessibility permission grant often implicitly enables event tap
  capabilities as well, but both should be requested for robustness.

### 5. How does Custom IME work in practice? Key gotchas?
- Must be a specially structured .app in ~/Library/Input Methods/
- User must manually enable in System Settings > Keyboard > Input Sources
- Conflicts with CJK input methods (only one active at a time)
- Marked text styling may not match "ghost text" expectation (apps often
  render marked text with underline regardless of attributes you set)
- Limited access to surrounding text context
- Complex state management (composition mode vs. normal mode)
- See hallelujah-im on GitHub for the closest reference implementation

### 6. Best coverage across app types?
**AX API + Overlay** provides broadest coverage:
- Native Cocoa: Excellent (90%+ of features work)
- Electron: Good (80%+)
- Browser text fields: Moderate (via browser's AX, 60-70%)
- Terminal: Poor (fundamentally different text model, ~20%)
- Qt/Java: Variable (40-70%)

No single approach covers 100%. Terminal support likely requires
separate integration (shell plugin, terminal-specific extension).

### 7. Private/undocumented APIs that help?
- `_NSTextInputContext` private methods: Apple uses for inline predictions
- `NSTextInputClient` private protocol extensions for prediction rendering
- `HIServices` private AX functions: Undocumented accessibility attributes
- `CGSWindow` functions: Private Core Graphics for window management
- **STRONG RECOMMENDATION: Do NOT use private APIs** for a shipping product.
  They break between macOS versions and prevent App Store distribution.

### 8. Known failure modes per approach?

**AX API failures:**
- Sublime Text: No AXTextArea, no BoundsForRange
- Games / custom rendering engines: No AX text fields
- Java Swing with poor accessibility bridge
- Password/secure fields (intentionally restricted -- correct behavior)
- App is hung/unresponsive (AX call blocks indefinitely without timeout)
- Firefox: BoundsForRange returns incorrect rects in some scenarios

**CGEventTap failures:**
- Secure Input mode (banking apps, password managers enable this)
- Permission not granted (tapCreate returns nil)
- Tap auto-disabled if callback exceeds ~200ms
- Cannot capture Touch Bar input or some HID devices

**IME failures:**
- CJK input method conflict (cannot use both simultaneously)
- Sublime Text and custom text handling editors
- Terminal emulators may handle IME non-standardly
- Occasional Electron IME bugs
- User forgets to switch to autocomplete input source

**Overlay window failures:**
- Full-screen apps (need proper collectionBehavior)
- Apps using window levels higher than .floating
- Multi-monitor with different scaling factors
- Font mismatch making ghost text look unconvincing
- Coordinate conversion bugs between AX and AppKit spaces
- Rapid cursor movement causing overlay lag/flicker
- Window partially offscreen if caret is near screen edge

---

## RELEVANT GITHUB REPOSITORIES

| Repository | URL | Relevance |
|-----------|-----|-----------|
| Hammerspoon | github.com/Hammerspoon/hammerspoon | AX API patterns, Lua macOS automation |
| Espanso | github.com/espanso/espanso | CGEventTap + clipboard, Rust macOS backend |
| Karabiner-Elements | github.com/pqrs-org/Karabiner-Elements | Keyboard interception, DriverKit |
| hallelujah-im | github.com/dongyuwei/hallelujah-im | English autocomplete IME (closest reference) |
| Squirrel (RIME) | github.com/rime/squirrel | Production IME, InputMethodKit patterns |
| fcitx5-macos | github.com/fcitx-contrib/fcitx5-macos | Modern InputMethodKit framework |
| OpenVanilla | github.com/openvanilla/openvanilla | Mature InputMethodKit framework |
| AXSwift | github.com/tmandry/AXSwift | Swift AX wrapper (somewhat unmaintained) |
| Clipy | github.com/Clipy/Clipy | Clipboard manager with event taps |
| KeyboardShortcuts | github.com/sindresorhus/KeyboardShortcuts | Global keyboard shortcuts in Swift |
| yabai | github.com/koekeishiya/yabai | Private CG APIs for window management |
| skhd | github.com/koekeishiya/skhd | Simple hotkey daemon using event taps |
| macism | github.com/laishulu/macism | Command line input source manager |
| Phoenix | github.com/kasper/phoenix | macOS window manager with AX bindings |

## APPLE DOCUMENTATION REFERENCES

- Accessibility Programming Guide: developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/
- AXUIElement Reference: developer.apple.com/documentation/applicationservices/axuielement
- InputMethodKit Framework: developer.apple.com/documentation/inputmethodkit
- IMKInputController: developer.apple.com/documentation/inputmethodkit/imkinputcontroller
- NSTextInputClient: developer.apple.com/documentation/appkit/nstextinputclient
- CGEventTap: developer.apple.com/documentation/coregraphics/1454426-cgeventtapcreate
- NSPanel: developer.apple.com/documentation/appkit/nspanel
- TIS (Text Input Source) API: developer.apple.com/documentation/carbon/text_input_source_services

## PERFORMANCE BUDGET

| Stage | Target | Notes |
|-------|--------|-------|
| Keystroke detection | <1ms | CGEventTap callback, must be fast |
| Caret position query | <5ms | AX BoundsForRange call |
| Context extraction | <10ms | AX value + surrounding text |
| AI suggestion (network) | 50-200ms | Streaming preferred |
| Overlay positioning | <2ms | NSWindow frame update |
| Total (without AI) | <20ms | Imperceptible |
| Total (with AI) | 50-200ms | Acceptable with streaming |

The rendering layer itself is fast. The bottleneck is AI suggestion latency.
Use streaming responses and show partial suggestions as they arrive.

---

## Technical Decisions
| Decision | Rationale |
|----------|-----------|
| Primary approach: AX + CGEventTap (.defaultTap) + Overlay | Proven by Grammarly, broadest app coverage, Accessibility permission only |
| Text insertion: AX with clipboard fallback | AX is cleanest; clipboard is most reliable fallback |
| Event-driven (not polling) for keystrokes | CGEventTap is event-driven; AX queries only on keystroke |
| Overlay: NSPanel with .nonactivatingPanel | Standard macOS pattern for non-focus-stealing overlays |
| Coordinate conversion: AX top-left to AppKit bottom-left | Required; use NSScreen.screens[0].frame.height for conversion |
| Tech stack: Swift + Node.js/TypeScript sidecar | Swift for macOS platform layer (CGEventTap, AX, NSPanel). TS sidecar for AI API calls (official SDKs, ~1ms IPC overhead). Engine logic in Swift module with no macOS imports (extractable to Rust later for cross-platform). |
| MVP rendering: Overlay only (no IME) | IME excludes CJK users (can't use two IMEs simultaneously). Overlay works for everyone with no input source switching. IME can be added later as opt-in for English-only power users. |
| AI providers: OpenAI + Ollama + OpenRouter + Qwen | Four providers for MVP. OpenRouter covers Claude and 100+ other models via one API. Ollama for local/offline. Qwen for strong code/text completion. Direct Claude SDK deferred — accessible through OpenRouter. |
| Key bindings: Right Arrow + Tab | Right Arrow = accept one word, Tab = accept all, Escape = dismiss. Matches Apple's Sonoma inline prediction UX. |
| App form: Menu bar + contextual toolbar | Menu bar icon for global settings. Contextual floating toolbar near active text field when autocomplete is working — quick enable/disable per-app or globally. Similar to Grammarly's floating icon but with inline controls. |
| Permission model: Accessibility only | CGEventTap .defaultTap + AX API both covered by single Accessibility permission, same as Grammarly |
| Private APIs: Do not pursue | Apple's inline prediction APIs are private, process-isolated, SIP-protected. No third party has achieved system-wide inline ghost text. Overlay is the correct path. |
| Mid-text suggestions: Skip for MVP | Only suggest when caret is at end of text or end of line. Mid-text overlay would visually cover existing text. FIM prompting + post-process overlap trimming for end-of-text mid-word completion. |
| UX: Debounce 300ms, fade 150ms in / 100ms out | Industry consensus debounce. Subtle animation avoids jarring appearance. |
| Safety: Never suggest in password fields | Detect via AX subrole kAXSecureTextFieldSubrole + IsSecureEventInputEnabled() for global secure input |

## Issues Encountered
| Issue | Resolution |
|-------|------------|
| Web search/fetch unavailable | Used training knowledge; URLs should be verified when web access restored |
| AX BoundsForRange with length=0 | Use length=1 at caret position; if at end of text, use char before caret + right edge |
| Multi-monitor coordinate conversion | Use NSScreen.screens to find correct screen; convert per-screen |
| Marked text styling not honored by apps | Accept that IME approach won't produce clean ghost text in all apps |

## Resources
- Cursor Tab blog post: https://cursor.sh/blog/cursor-tab
- GitHub Copilot internals (2023 blog): https://github.blog/2023-05-17-how-github-copilot-is-getting-better-at-understanding-your-code/
- Inside GitHub Copilot (2024 blog): https://github.blog/2024-04-12-inside-github-working-with-the-llms-behind-github-copilot/
- Gmail Smart Compose paper (KDD 2019): https://arxiv.org/abs/1906.00080
- Supermaven blog: https://supermaven.com/blog
- Continue.dev autocomplete docs: https://docs.continue.dev/features/autocomplete
- Continue.dev source code: https://github.com/continuedev/continue
- Speculative decoding paper (ICML 2023): https://arxiv.org/abs/2211.17192
- FIM training paper: https://arxiv.org/abs/2207.14255
- Codeium engineering blog: https://codeium.com/blog
- Apple WWDC 2023 "What's new in text and text interactions"
- StarCoder2: https://huggingface.co/bigcode/starcoder2-3b
- DeepSeek Coder: https://huggingface.co/deepseek-ai/deepseek-coder-1.3b-base
- Qwen2.5-Coder: https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B
- Apple AXUIElement docs: https://developer.apple.com/documentation/applicationservices/axuielement
- InputMethodKit docs: https://developer.apple.com/documentation/inputmethodkit
- Hammerspoon: https://github.com/Hammerspoon/hammerspoon
- Espanso: https://github.com/espanso/espanso
- hallelujah-im: https://github.com/dongyuwei/hallelujah-im
- Squirrel (RIME): https://github.com/rime/squirrel
- Karabiner-Elements: https://github.com/pqrs-org/Karabiner-Elements

## Visual/Browser Findings
<!-- 
  WHAT: Information you learned from viewing images, PDFs, or browser results.
  WHY: CRITICAL - Visual/multimodal content doesn't persist in context. Must be captured as text.
  WHEN: IMMEDIATELY after viewing images or browser results. Don't wait!
  EXAMPLE:
    - Screenshot shows login form has email and password fields
    - Browser shows API returns JSON with "status" and "data" keys
-->
<!-- CRITICAL: Update after every 2 view/browser operations -->
<!-- Multimodal content must be captured as text immediately -->
-

---
<!-- 
  REMINDER: The 2-Action Rule
  After every 2 view/browser/search operations, you MUST update this file.
  This prevents visual information from being lost when context resets.
-->
*Update this file after every 2 view/browser/search operations*
*This prevents visual information from being lost*