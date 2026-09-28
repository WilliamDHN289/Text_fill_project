"""Replay corpora and typing scenarios, ported 1:1 from the Swift harnesses:

  small: ../../8_dpfm_application/Tests/DPFMemoryTests/DPFMExperimentTests.swift
  large: ../../8_dpfm_application/Tests/DPFMemoryTests/DPFMLargeScaleExperimentTests.swift

Timestamps mirror the Swift constants (base=1_750_000_000, day=86_400).
"""

from dataclasses import dataclass
from typing import List, Tuple

DAY = 86_400.0
BASE = 1_750_000_000.0


@dataclass(frozen=True)
class Scenario:
    partner: str
    prefix: str
    truth: Tuple[str, ...]
    category: str
    expect_hit: bool


# --------------------------------------------------------------------------
# Small harness: 9 messages, 7 scenarios (expected: ON 6/7, OFF 0/7)
# --------------------------------------------------------------------------

SMALL_CORPUS: List[Tuple[float, str, str]] = [
    (9, "Alice Chen", "The Phoenix launch is scheduled for 2026-08-15, pending legal sign-off."),
    (9, "Alice Chen", "Alice will own the Phoenix rollout checklist."),
    (7, "Bob Park",   "Budget review meeting moved to Friday 10am in room 4B."),
    (6, "Bob Park",   "We agreed the Q3 budget cap is $250k for infra."),
    (5, "Team Atlas", "Atlas API freeze is scheduled for Jul 28; no new endpoints after that."),
    (4, "Alice Chen", "Legal confirmed the Phoenix launch date, still 2026-08-15."),
    (3, "Carol Wu",   "Carol prefers the weekly sync at 9:30 instead of 10."),
    (2, "IT Support", "My laptop asset tag is C02-7841-XJ, needs a battery swap."),
    (1, "Bob Park",   "Vendor quote came in at $187k, under the cap we set."),  # known-limit
]

SMALL_SCENARIOS: List[Scenario] = [
    Scenario("Alice Chen", "Quick reminder: the Phoenix launch is on ",     ("2026-08-15",),  "direct",      True),
    Scenario("Bob Park",   "As discussed, our infra budget cap for Q3 is ", ("$250k",),       "direct",      True),
    Scenario("Team Atlas", "Heads up — the Atlas API freeze lands on ",     ("jul 28",),      "direct",      True),
    Scenario("Carol Wu",   "Moving our weekly sync to ",                    ("9:30",),        "direct",      True),
    Scenario("IT Support", "Following up on the battery swap, asset tag ",  ("c02-7841-xj",), "direct",      True),
    Scenario("Bob Park",   "The vendor quote was ",                         ("$187k",),       "known-limit", False),
    Scenario("Dan Lee",    "Alice is the owner of the rollout for ",        ("phoenix",),     "associative", True),
]

# --------------------------------------------------------------------------
# Large harness: 287 messages (31 seeds + 16 chitchat + 240 fillers),
# 25 scenarios in 5 categories (expected: ON 24/25, OFF 0/25)
# --------------------------------------------------------------------------

SEEDS: List[Tuple[float, str, str]] = [
    (28, "Alice Chen", "The Phoenix launch is scheduled for 2026-08-15, pending legal sign-off."),
    (27, "Alice Chen", "Alice will own the Phoenix rollout checklist."),
    (26, "Bob Park",   "Budget review meeting moved to Friday 10am in room 4B."),
    (25, "Bob Park",   "We agreed the Q3 budget cap is $250k for infra."),
    (24, "Team Atlas", "Atlas API freeze is scheduled for Jul 28; no new endpoints after that."),
    (23, "Carol Wu",   "Carol prefers the weekly sync at 9:30 instead of 10."),
    (22, "IT Support", "My laptop asset tag is C02-7841-XJ, needs a battery swap."),
    (21, "Bob Park",   "Vendor quote came in at $187k, under the cap we set."),  # known-limit: no signal verb
    (20, "Erin Gomez", "The security audit is due on Sep 12; Erin will send the checklist."),
    (19, "Finance",    "Invoice INV-20449 was sent to Finance for $12,400."),
    (18, "Dan Lee",    "Dan owns the Kestrel migration runbook."),
    (17, "Team Atlas", "Atlas staging access needs VPN profile v3."),
    (16, "HR Desk",    "Onboarding for the new analyst is scheduled for Aug 3."),
    (15, "Frank Liu",  "Frank confirmed the design review moved to Thursday 2pm."),
    (14, "Legal",      "Legal decided the data-retention window is 18 months."),
    (13, "Alice Chen", "Legal confirmed the Phoenix launch date, still 2026-08-15."),
    (12, "Erin Gomez", "Erin needs the pentest findings by Aug 20."),
    (11, "Carol Wu",   "Carol will present the roadmap at the all-hands on Sep 5."),
    (10, "IT Support", "The monitor RMA number is RMA-55302, replacement is due next week."),
    (9,  "Bob Park",   "Bob agreed the contractor day rate is $950."),
    (8,  "Dan Lee",    "Kestrel cutover is scheduled for 2026-09-01 at 06:00 UTC."),
    (7,  "Frank Liu",  "Frank sent the print vendor deposit of $3,750."),
    (6,  "Team Atlas", "Atlas SLA target is 99.95% for Q4."),
    (5,  "HR Desk",    "The offsite hotel block code is FLOW26; booking deadline is Aug 8."),
    (4,  "Legal",      "The NDA template v4 is the only approved version."),
    (3,  "Alice Chen", "Alice moved the Phoenix go/no-go call to Aug 11 at 14:00."),
    (2,  "Finance",    "Finance confirmed the PO number for the GPU order is PO-88231."),
    (1,  "Ops Oncall", "The oncall handoff meeting is daily at 09:15."),
    (2,  "Bob Park",   "Budget review meeting moved to Monday 2pm in room 4B."),  # supersedes Friday fact by recency
    (6,  "王小明",      "凤凰项目的上线时间定于8月15日。"),
    (5,  "王小明",      "王小明负责凤凰项目的数据迁移验收。"),
]

KNOWN_LIMIT_SEEDS = 1  # the $187k sentence: no signal verb, expected extractor miss

CHITCHAT: List[str] = [
    "Sounds good, talk later!",
    "Haha nice, thanks a lot!",
    "Perfect, thanks!",
    "Can you resend that?",
    "No worries at all.",
    "Great, appreciate it!",
    "Sure thing, ping me anytime.",
    "Got it, thanks so much.",
    "Awesome news!",
    "Talk tomorrow?",
    "Safe travels!",
    "Congrats again on the demo!",
    "Let me check and get back to you.",
    "Running late, start without me.",
    "Good catch, updating now.",
    "Coffee first, then the standup.",
]


def fillers() -> List[Tuple[float, str, str]]:
    """240 synthetic filler facts (4 templates x 60): extractable, off-topic."""
    names = ["Sam Torres", "Nina Patel", "Omar Haddad", "Lucy Zhang",
             "Raj Mehta", "Ivy Novak", "Theo Brandt", "Mia Costa"]
    out: List[Tuple[float, str, str]] = []
    for i in range(60):
        d = float(i % 28 + 1)
        out.append((d, "Jira Bot",       f"Ticket QA-{1000 + i} is assigned to {names[i % 8]}."))
        out.append((d, "Deploy Bot",     f"Build {2400 + i} was deployed to staging."))
        out.append((d, "Ops Board",      f"Server rack R{10 + i} needs a firmware update."))
        out.append((d, "Inventory Desk", f"License seat L-{500 + i} is reserved for {names[(i + 3) % 8]}."))
    return out


def large_corpus() -> List[Tuple[float, str, str]]:
    """All 287 messages, oldest first (mirrors the Swift sort)."""
    msgs = list(SEEDS) + fillers()
    for i, text in enumerate(CHITCHAT):
        msgs.append((float(i % 28 + 1), SEEDS[i % len(SEEDS)][1], text))
    msgs.sort(key=lambda m: -m[0])  # descending daysAgo == oldest first
    return msgs


LARGE_SCENARIOS: List[Scenario] = [
    # -- direct recall: dates ------------------------------------------------
    Scenario("Alice Chen", "Quick reminder: the Phoenix launch is on ",       ("2026-08-15",),  "direct", True),
    Scenario("Team Atlas", "Heads up — the Atlas API freeze lands on ",       ("jul 28",),      "direct", True),
    Scenario("Erin Gomez", "The security audit deadline is ",                 ("sep 12",),      "direct", True),
    Scenario("Dan Lee",    "The Kestrel cutover is scheduled for ",           ("2026-09-01",),  "direct", True),
    Scenario("HR Desk",    "Onboarding for the new analyst is on ",           ("aug 3",),       "direct", True),
    Scenario("Erin Gomez", "Please share the pentest findings by ",           ("aug 20",),      "direct", True),
    Scenario("Carol Wu",   "Carol presents the roadmap at the all-hands on ", ("sep 5",),       "direct", True),
    Scenario("Alice Chen", "The Phoenix go/no-go call is now ",               ("aug 11",),      "direct", True),
    # -- direct recall: amounts ----------------------------------------------
    Scenario("Bob Park",   "As agreed, our Q3 infra budget cap is ",          ("$250k",),       "direct", True),
    Scenario("Bob Park",   "The contractor day rate we agreed is ",           ("$950",),        "direct", True),
    Scenario("Frank Liu",  "The print vendor deposit was ",                   ("$3,750",),      "direct", True),
    Scenario("Team Atlas", "Our Atlas SLA target for Q4 is ",                 ("99.95%",),      "direct", True),
    Scenario("Legal",      "Our data-retention window is ",                   ("18 months",),   "direct", True),
    # -- direct recall: identifiers ------------------------------------------
    Scenario("IT Support", "Following up on the battery swap, asset tag ",    ("c02-7841-xj",), "direct", True),
    Scenario("Finance",    "Checking on invoice ",                            ("inv-20449",),   "direct", True),
    Scenario("IT Support", "The monitor RMA number is ",                      ("rma-55302",),   "direct", True),
    Scenario("HR Desk",    "The hotel block code for the offsite is ",        ("flow26",),      "direct", True),
    Scenario("Finance",    "The PO number for the GPU order is ",             ("po-88231",),    "direct", True),
    # -- direct recall: times ------------------------------------------------
    Scenario("Carol Wu",   "Moving our weekly sync to ",                      ("9:30",),        "direct", True),
    Scenario("Ops Oncall", "Reminder: oncall handoff is daily at ",           ("09:15",),       "direct", True),
    # -- associative: prefix never names the target entity -------------------
    Scenario("Grace Kim",  "Alice is the owner of the rollout for ",          ("phoenix",),     "associative", True),
    Scenario("Grace Kim",  "Dan is the person to ask about ",                 ("kestrel",),     "associative", True),
    # -- conflict: keyless contradiction, newest value must be present -------
    Scenario("Bob Park",   "Budget review is now on ",                        ("monday 2pm",),  "conflict", True),
    # -- cjk: gazetteer entities + CJK signal verbs --------------------------
    Scenario("王小明",      "提醒一下，凤凰项目的上线时间是",                       ("8月15日",),      "cjk", True),
    # -- known extraction limit: source sentence has no signal verb ----------
    Scenario("Bob Park",   "The vendor quote was ",                           ("$187k",),       "known-limit", False),
]


def prompt_contains(block: str, tokens) -> bool:
    low = block.lower()
    return all(t.lower() in low for t in tokens)
