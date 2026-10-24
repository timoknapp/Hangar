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
    issue(9, [marker(outcome="failed", autoRetry=True, **{"class": "infrastructure"}),
              marker(outcome="ready")]),                                          # auto retry then clean
    issue(10, [marker(outcome="failed", autoRetry=True, **{"class": "infrastructure"}),
               marker(outcome="failed", autoRetry=False, **{"class": "infrastructure"})]),  # retry used up
]
r = fm.report(issues)
rows = {x["number"]: x for x in r["issues"]}
assert rows[1]["clean"] and rows[4]["clean"] and rows[6]["clean"] and rows[8]["clean"]
assert not rows[2]["clean"] and rows[2]["humanRetries"] == 1
assert rows[3]["awaitingAnswer"] and not rows[3]["attempted"], "a pending question is neither success nor failure"
assert rows[5]["source"] == "legacy" and not rows[5]["clean"]
assert not rows[7]["attempted"] and rows[7]["invalidReceipts"] == 1, "invalid receipts never count as success"
assert rows[9]["clean"] and rows[9]["autoRetries"] == 1, "a failure taken over by the automatic retry is no intervention"
assert not rows[10]["clean"] and rows[10]["failures"] == 1
assert r["attempted"] == 8 and r["cleanReady"] == 5 and r["autoRetries"] == 2, r
assert r["failureClasses"] == {"infrastructure": 4, "unknown": 1}, r["failureClasses"]
assert r["implementerCredits"] == "unknown", "one unknown makes the total unknown"
assert r["legacyIssues"] == 2 and r["awaitingAnswer"] == 1 and r["invalidReceipts"] == 1
assert r["questionsPerIssue"] == round(2 / 9, 2)
assert fm.report([])["cleanRate"] is None
print("PASS: metrics count interventions, questions, legacy fallback and unknown usage")

# --since is attempt time, not issue creation: an old issue attempted after the
# cut-off counts, and only with its later activity.
old = {"number": 9, "prMerged": True,
       "comments": [{"body": marker(outcome="failed", **{"class": "review"}), "bot": True, "at": "2026-09-01T10:00:00Z"},
                    {"body": marker(outcome="ready"), "bot": True, "at": "2026-10-23T17:35:00Z"}],
       "events": [{"event": "unlabeled", "label": "squad:failed", "bot": False, "at": "2026-09-02T08:00:00Z"}]}
untouched = {"number": 10, "prMerged": True,
             "comments": [{"body": marker(outcome="ready"), "bot": True, "at": "2026-09-01T10:00:00Z"}], "events": []}
r = fm.report(fm.since_filter([old, untouched], "2026-10-22"))
assert r["attempted"] == 1 and r["cleanReady"] == 1, r
assert fm.report(fm.since_filter([old, untouched], "1970-01-01"))["cleanReady"] == 1
print("PASS: --since counts attempts after the cut-off, including old issues, and drops earlier history")
