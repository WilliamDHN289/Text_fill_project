"""Unit tests for the construction and serving invariants.

    python3.11 -m pytest tests      (or: python3.11 tests/test_pfm.py)
"""

import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import common as C  # noqa: E402
import extractor as X  # noqa: E402
import pfm  # noqa: E402

CFG = C.load_config()["pfm"]
GAZ = ["Alex Chen", "Alex Rivera", "Halcyon"]


def store(cfg=CFG, keyed=True):
    ex = X.make_keyed_extractor(GAZ)
    return pfm.PFM(cfg, ex if keyed else X.strip_keys(ex))


def active_texts(s):
    return [f.text for f in s.facts.values() if f.active]


def test_verbatim_revision_supersedes_keyed():
    s = store()
    s.ingest("The standup with Alex Chen is moved to 9:30am.", ["Alex Chen"], 0)
    s.ingest("The standup with Alex Chen is moved to 10:45am.", ["Alex Chen"], 1)
    assert active_texts(s) == ["The standup with Alex Chen is moved to 10:45am."]


def test_verbatim_revision_not_absorbed_keyless():
    s = store(keyed=False)
    s.ingest("The standup with Alex Chen is moved to 9:30am.", ["Alex Chen"], 0)
    s.ingest("The standup with Alex Chen is moved to 10:45am.", ["Alex Chen"], 1)
    assert len(active_texts(s)) == 2


def test_exact_repeat_is_reobservation():
    s = store(keyed=False)
    s.ingest("The standup with Alex Chen is moved to 9:30am.", ["Alex Chen"], 0)
    s.ingest("The standup with Alex Chen is moved to 9:30am.", ["Alex Chen"], 5)
    (f,) = s.facts.values()
    assert f.last_seen == 5 and f.usage.value > 0


def test_usage_inherited_on_supersession():
    s = store()
    s.ingest("The standup with Alex Chen is moved to 9:30am.", ["Alex Chen"], 0)
    old = next(iter(s.facts.values()))
    s.mark_served([old.fact_id], 0)
    s.ingest("The standup with Alex Chen is moved to 10:45am.", ["Alex Chen"], 0)
    new = next(f for f in s.facts.values() if f.active)
    assert new.usage.value == old.usage.value == 1.0


def test_prune_keeps_only_active_value_of_every_key():
    s = store()
    s.ingest("The standup with Alex Chen is moved to 9:30am.", ["Alex Chen"], 0)
    s.ingest("Alex Rivera is sending the Halcyon notes.", ["Alex Rivera"], 0)
    s.prune(now=10 ** 9)                      # everything is ancient
    assert active_texts(s) == ["The standup with Alex Chen is moved to 9:30am."]


def test_greedy_rule_stops_at_first_overflow():
    facts = [pfm.Fact(i, "x" * n, (), (), None, 0.0) for i, n in enumerate([40, 400, 10])]
    header = len(pfm.BLOCK_HEADER)
    line = lambda f: 1 + len(pfm.fact_line(f))
    budget = header + line(facts[0]) + 5
    assert pfm.select(facts, k=6, budget=budget) == facts[:1]
    block = pfm.format_block(pfm.select(facts, k=6, budget=10 ** 4))
    assert len(pfm.format_block(pfm.select(facts, k=6, budget=len(block)))) <= len(block)


def test_readers_never_see_two_active_values_during_updates():
    s = store()
    stop, violations = threading.Event(), []

    def writer():
        for i in range(2000):
            s.ingest(f"The standup with Alex Chen is moved to {i % 12 + 1}:{i % 60:02d}am.",
                     ["Alex Chen"], i)
        stop.set()

    t = threading.Thread(target=writer)
    t.start()
    while not stop.is_set():
        facts = [f for f, _ in s.rank("the standup with Alex is at", ["Alex Chen"], 10 ** 4)]
        if sum(f.key == ("alex chen", "meeting") for f in facts) > 1:
            violations.append(facts)
    t.join()
    assert not violations


def test_fresh_request_falls_back_and_cancels():
    s = store()
    s.ingest("The standup with Alex Chen is moved to 9:30am.", ["Alex Chen"], 0)
    server = pfm.Server(s)
    published = server.publish("standup with Alex", ["Alex Chen"], 0)
    with s.lock:                               # construction holds the lock
        snap, source = server.fresh("standup with Alex", ["Alex Chen"], 0, wait_s=0.01)
    assert source == "snapshot" and snap is published


def test_unanswerable_request_is_clean_only_when_nothing_is_exposed():
    """Eq. (1), second case: recall is undefined, so the score is exposure."""
    import benchmark as B
    import metrics as M
    q = B.Query("u-q0", "Alex Chen", "the standup with Alex is in ", None, [], ["room 4B"], {})
    assert M.outcome("[Relevant memory]\n- (2025-01-01) room 4B", q)["clean"] is False
    empty = M.outcome("", q)
    assert empty["clean"] is True and empty["abstain"] is True


def test_identity_posterior_only_fires_on_an_ambiguous_mention():
    import identity as I
    s = store()
    s.ingest("The standup with Alex Chen is moved to 9:30am.", ["Alex Chen"], 0)
    s.ingest("The standup with Alex Rivera is moved to 4:15pm.", ["Alex Rivera"], 0)
    s.ingest("The Halcyon launch is scheduled for 2026-09-01.", ["Alex Chen"], 0)
    post = I.resolve(s, "the standup with Alex is at ", ["Alex Chen"], 1)
    assert set(post) == {"alex chen", "alex rivera"}
    assert max(post, key=post.get) == "alex chen"
    assert I.resolve(s, "the Halcyon launch is scheduled for ", ["Alex Chen"], 1) == {}


def test_cluster_id_separates_the_same_chain_in_two_corpora():
    import metrics as M
    assert M.cluster_id({"qid": "noisy-s7-c3-q0"}) != M.cluster_id({"qid": "noisy-s11-c3-q0"})


def test_tost_needs_more_than_a_null_result():
    """A difference that is not significant is not equivalence; a wide, centred
    interval must fail the margin even though the point estimate is zero."""
    import metrics as M
    a = [{"qid": str(i), "seed": 0, "clean": i % 2 == 0} for i in range(40)]
    b = [{"qid": str(i), "seed": 0, "clean": i % 4 == 0} for i in range(40)]
    assert M.tost(a, b, margin=0.02)["equivalent"] is False
    assert M.tost(a, a, margin=0.02)["equivalent"] is True


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
