#!/usr/bin/env python3
"""Synthetic fixtures for tools/factory-metrics.py (no network)."""
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("fm", ROOT / "tools/factory-metrics.py")
fm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fm)


def marker(**kw):
    base = {"v": 1, "worker": "w1", "kind": "issue", "stage": "publish", "class": None,
            "seconds": 60, "implementerCredits": 100}
    base.update(kw)
    return f"text\n<!-- hangar-receipt {json.dumps(base)} -->"


def issue(n, comments=(), events=(), merged=False):
    return {"number": n, "comments": [{"body": b, "bot": True} for b in comments],
            "events": list(events), "prMerged": merged}


# parser: missing, empty, malformed, unknown version, bad fields
assert fm.parse_receipts("") == []
assert fm.parse_receipts(None) == []
assert fm.parse_receipts("<!-- hangar-receipt {nope} -->") == [{"invalid": "json"}]
assert fm.parse_receipts("<!-- hangar-receipt {\"v\":2,\"outcome\":\"ready\"} -->") == [{"invalid": "version"}]
assert fm.parse_receipts(marker(outcome="merged")) == [{"invalid": "fields"}]
assert fm.parse_receipts(marker(outcome="failed", **{"class": "weird"})) == [{"invalid": "fields"}]
assert fm.parse_receipts(marker(outcome="ready"))[0]["outcome"] == "ready"
print("PASS: receipt parser rejects missing/malformed/unknown-version/bad-field markers")

human_retry = {"event": "unlabeled", "label": "squad:failed", "bot": False}
issues = [
    issue(1, [marker(outcome="ready")]),                                          # clean
    issue(2, [marker(outcome="failed", **{"class": "infrastructure"}),
              marker(outcome="ready")], [human_retry]),                           # intervention
    issue(3, [marker(outcome="no-change", **{"class": "decision"})]),             # awaiting answer
    issue(4, [marker(outcome="no-change", **{"class": "decision"}),
              marker(outcome="ready", implementerCredits="unknown")]),            # question then clean
    issue(5, events=[{"event": "labeled", "label": "squad:failed", "bot": True}]),  # legacy failure
    issue(6, events=[{"event": "labeled", "label": "squad:done", "bot": True}], merged=True),  # legacy clean
    issue(7, ["<!-- hangar-receipt {broken} -->"]),                                 # only invalid receipts
    issue(8, [marker(outcome="draft")]),                                          # task-mandated draft
]
r = fm.report(issues)
rows = {x["number"]: x for x in r["issues"]}
assert rows[1]["clean"] and rows[4]["clean"] and rows[6]["clean"] and rows[8]["clean"]
assert not rows[2]["clean"] and rows[2]["humanRetries"] == 1
assert rows[3]["awaitingAnswer"] and not rows[3]["attempted"], "a pending question is neither success nor failure"
assert rows[5]["source"] == "legacy" and not rows[5]["clean"]
assert not rows[7]["attempted"] and rows[7]["invalidReceipts"] == 1, "invalid receipts never count as success"
assert r["attempted"] == 6 and r["cleanReady"] == 4, r
assert r["failureClasses"] == {"infrastructure": 1, "unknown": 1}, r["failureClasses"]
assert r["implementerCredits"] == "unknown", "one unknown makes the total unknown"
assert r["legacyIssues"] == 2 and r["awaitingAnswer"] == 1 and r["invalidReceipts"] == 1
assert r["questionsPerIssue"] == round(2 / 7, 2)
assert fm.report([])["cleanRate"] is None
print("PASS: metrics count interventions, questions, legacy fallback and unknown usage")
