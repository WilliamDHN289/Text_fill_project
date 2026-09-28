# Task Plan: [Brief Description]
<!-- 
  WHAT: This is your roadmap for the entire task. Think of it as your "working memory on disk."
  WHY: After 50+ tool calls, your original goals can get forgotten. This file keeps them fresh.
  WHEN: Create this FIRST, before starting any work. Update after each phase completes.
-->


## Goal
<!-- 
  WHAT: One clear sentence describing what you're trying to achieve.
  WHY: This is your north star. Re-reading this keeps you focused on the end state.
  EXAMPLE: "Create a Python CLI todo app with add, list, and delete functionality."
-->
I want to build an autocomplete-anywhere experience on macOS—similar to Cursor’s Tab completion or Gmail’s inline suggestions—where users receive real-time completion as they type in any app.


## Current Phase
<!-- 
  WHAT: Which phase you're currently working on (e.g., "Phase 1", "Phase 3").
  WHY: Quick reference for where you are in the task. Update this as you progress.
-->
Phase 3

## Phases
<!-- 
  WHAT: Break your task into 3-7 logical phases. Each phase should be completable.
  WHY: Breaking work into phases prevents overwhelm and makes progress visible.
  WHEN: Update status after completing each phase: pending → in_progress → complete
-->

### Phase 1: Requirements & Discovery
<!-- 
  WHAT: Understand what needs to be done and gather initial information.
  WHY: Starting without understanding leads to wasted effort. This phase prevents that.
-->
- [x] Understand and confirm user intent in each of the following steps
- [x] Learn all the plugins installed now and explain to me, and suggest to me where fit
- [x] extensive research on existing articles and GitHub repositories to find solutions for two main challenges.
	1.	Autocomplete engine: Responsible for generating high-quality suggestions and defining the logic that creates a seamless, helpful user experience.
	2.	Front-end rendering layer: Able to display inline suggestions directly after the caret in any macOS application, regardless of where the user is typing.
- [x] For the auto-complete engine: conduct thorough research (10 questions across 7 projects, 800+ lines in findings.md)
- [x] For the front-end engine: researched 4 approaches, analyzed Grammarly/Espanso/hallelujah-im/Squirrel, 1300+ lines in findings.md
- [x] Used superpowers to brainstorm — walked through all key decisions with user
- [x] Researched Apple private APIs (dead end — SIP/process isolation prevents system-wide inline ghost text)
- [x] Document findings in findings.md (2,224 lines total)
- **Decisions made:**
  - Tech stack: Swift + Node.js/TypeScript sidecar
  - Rendering: AX + CGEventTap (.defaultTap) + NSPanel overlay (no IME in MVP)
  - Permissions: Accessibility only
  - AI providers: OpenAI + Ollama + OpenRouter + Qwen (Claude accessible via OpenRouter)
  - Key bindings: Right Arrow (accept word), Tab (accept all), Escape (dismiss)
  - App form: Menu bar + contextual floating toolbar near active text field
  - Private APIs: Not pursuing
- **Status:** complete
<!-- 
  STATUS VALUES:
  - pending: Not started yet
  - in_progress: Currently working on this
  - complete: Finished this phase
-->

### Phase 2: Planning & Structure
<!-- 
  WHAT: Decide how you'll approach the problem and what structure you'll use.
  WHY: Good planning prevents rework. Document decisions so you remember why you chose them.
-->
- [x] Define what an MVP should look like after your research
- [x] Choose an initial end-to-end architecture (capture context → generate suggestion → render inline)
- [x] Define interfaces between components (context extraction, suggestion service, rendering/overlay)
- [x] Decide which macOS APIs/approaches to prioritize for caret + text extraction (AX + CGEventTap + NSPanel overlay)
- [x] Define UX rules (trigger, display, acceptance, safety)
- [x] Discussed mid-word completion strategy, key binding conflicts, provider scoping
- [x] Document decisions with rationale → docs/plans/2026-02-06-mvp-architecture-design.md
- **Status:** complete

### Phase 3: Implementation
<!-- 
  WHAT: Actually build/create/write the solution.
  WHY: This is where the work happens. Break into smaller sub-tasks if needed.
-->
- [ ] Build a minimal macOS prototype. Write code to files before executing.
- [ ] Implement an inline suggestion renderer (overlay or inline composition) that appears immediately after the caret
- [ ] Implement an autocomplete suggestion pipeline (context → request → completion) 
- [ ] Add UX logic that you learned and summarized from other auto-complete projects.
- [ ] Add acceptance controls and rejection/escape behavior
- [ ] Instrument latency and quality metrics (p50/p90, suggestion acceptance rate)
- [ ] Test incrementally and keep changes small per iteration


- **Status:** pending

### Phase 4: Testing & Verification
<!-- 
  WHAT: Verify everything works and meets requirements.
  WHY: Catching issues early saves time. Document test results in progress.md.
-->
- [ ] Validate caret positioning and rendering across a representative set of apps (native + Electron + browsers)
- [ ] Validate correctness for edge cases (mid-word completion, multi-line fields, IME, password fields, rich text)
- [ ] Measure and record end-to-end latency (capture → suggestion → render) and reliability
- [ ] Document test results and findings in progress.md
- [ ] Fix issues found and update decisions/assumptions accordingly

- **Status:** pending

### Phase 5: Delivery
<!-- 
  WHAT: Final review and handoff to user.
  WHY: Ensures nothing is forgotten and deliverables are complete.
-->
- [ ] Summarize the researched solutions and chosen approach for both challenges
- [ ] Provide a runnable prototype (or clear build/run instructions) and a short demo checklist
- [ ] Ensure documentation is complete (architecture, UX rules, limitations, next steps)
- [ ] Review all output files and deliver final artifacts
- **Status:** pending

## Key Questions
<!-- 
  WHAT: Important questions you need to answer during the task.
  WHY: These guide your research and decision-making. Answer them as you go.
  EXAMPLE: 
    1. Should tasks persist between sessions? (Yes - need file storage)
    2. What format for storing tasks? (JSON file)
-->
1. What is a good UX logic for auto-complete? 
2. How to locate caret in any app and show an inline suggestion anywhere?


## Decisions Made
<!-- 
  WHAT: Technical and design decisions you've made, with the reasoning behind them.
  WHY: You'll forget why you made choices. This table helps you remember and justify decisions.
  WHEN: Update whenever you make a significant choice (technology, approach, structure).
  EXAMPLE:
    | Use JSON for storage | Simple, human-readable, built-in Python support |
-->
| Decision | Rationale |
|----------|-----------|
|          |           |

## Errors Encountered
<!-- 
  WHAT: Every error you encounter, what attempt number it was, and how you resolved it.
  WHY: Logging errors prevents repeating the same mistakes. This is critical for learning.
  WHEN: Add immediately when an error occurs, even if you fix it quickly.
  EXAMPLE:
    | FileNotFoundError | 1 | Check if file exists, create empty list if not |
    | JSONDecodeError | 2 | Handle empty file case explicitly |
-->
| Error | Attempt | Resolution |
|-------|---------|------------|
|       | 1       |            |

## Notes
<!-- 
  REMINDERS:
  - Update phase status as you progress: pending → in_progress → complete
  - Re-read this plan before major decisions (attention manipulation)
  - Log ALL errors - they help avoid repetition
  - Never repeat a failed action - mutate your approach instead
-->
- Update phase status as you progress: pending → in_progress → complete
- Re-read this plan before major decisions (attention manipulation)
- Log ALL errors - they help avoid repetition