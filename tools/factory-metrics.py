#!/usr/bin/env python3
"""Hangar reliability metrics computed from GitHub alone.

Usage: factory-metrics.py OWNER/REPO [OWNER/REPO ...] [--since YYYY-MM-DD] [--json]
       factory-metrics.py --fixture issues.json   (offline; for tests)

Main metric: share of approved, attempted issues that reached a ready pull
request without manual intervention. Intervention = a human removed
squad:failed (explicit retry) or an attempt ended failed and the issue never
reached ready. Questions to humans (needs-* or no-change decisions) are not
intervention. Receipts (<!-- hangar-receipt {...} -->) are authoritative;
issues without receipts fall back to label history and are marked "legacy".
Reads only; requires an authenticated `gh`.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

RECEIPT = re.compile(r"<!-- hangar-receipt (\{.*?\}) -->")
OUTCOMES = {"ready", "draft", "ci-revision", "failed", "no-change"}
CLASSES = {None, "infrastructure", "policy", "code", "review", "decision", "unclassified"}


def parse_receipts(body: str) -> list[dict]:
    """Return valid receipts; malformed or unknown-version markers are reported, never trusted."""
    found = []
    for raw in RECEIPT.findall(body or ""):
        try:
            r = json.loads(raw)
        except json.JSONDecodeError:
            found.append({"invalid": "json"})
            continue
        if not isinstance(r, dict) or r.get("v") != 1:
            found.append({"invalid": "version"})
        elif r.get("outcome") not in OUTCOMES or r.get("class") not in CLASSES:
            found.append({"invalid": "fields"})
        else:
            found.append(r)
    return found


def summarize_issue(issue: dict) -> dict:
    """issue: {number, comments:[{body, author}], events:[{event, label, actor}]}."""
    receipts = [r for c in issue.get("comments", []) if c.get("bot", True)
                for r in parse_receipts(c.get("body", ""))]
    invalid = sum(1 for r in receipts if "invalid" in r)
    receipts = [r for r in receipts if "invalid" not in r]
    retries = sum(1 for e in issue.get("events", [])
                  if e.get("event") == "unlabeled" and e.get("label") == "squad:failed" and not e.get("bot"))
    if receipts:
        source = "receipt"
        ready = any(r["outcome"] in ("ready", "draft") for r in receipts)
        failed = [r for r in receipts if r["outcome"] == "failed"]
        # A failure the automatic retry took over is not a human intervention.
        failures = [r for r in failed if r.get("autoRetry") is not True]
        questions = sum(1 for r in receipts if r["outcome"] == "no-change")
        credits = [r.get("implementerCredits") for r in receipts]
        known = all(isinstance(c, int) for c in credits)
        usage = sum(credits) if known else "unknown"
        classes = [r.get("class") or "none" for r in failed]
        auto_retries = len(failed) - len(failures)
        attempts = len(receipts)
    else:
        source = "legacy"
        labeled = [e for e in issue.get("events", []) if e.get("event") == "labeled"]
        failures = [e for e in labeled if e.get("label") == "squad:failed"]
        ready = any(e.get("label") == "squad:done" for e in labeled) and issue.get("prMerged", False)
        questions, usage, classes, attempts = 0, "unknown", ["unknown"] * len(failures), len(failures) + int(ready)
        auto_retries = 0
    # Waiting on a human answer is neither success nor failure yet.
    awaiting = not ready and not failures and questions > 0
    attempted = (attempts > 0 or bool(failures)) and not awaiting
    clean = attempted and ready and not failures and retries == 0
    return {"number": issue["number"], "source": source, "attempted": attempted, "ready": ready,
            "awaitingAnswer": awaiting,
            "clean": clean, "attempts": attempts, "failures": len(failures), "humanRetries": retries,
            "questions": questions, "autoRetries": auto_retries, "classes": classes, "implementerCredits": usage, "invalidReceipts": invalid}


def report(issues: list[dict]) -> dict:
    rows = [summarize_issue(i) for i in issues]
    attempted = [r for r in rows if r["attempted"]]
    asked = [r for r in rows if r["attempted"] or r["awaitingAnswer"]]
    classes: dict[str, int] = {}
    for r in attempted:
        for c in r["classes"]:
            classes[c] = classes.get(c, 0) + 1
    credits = [r["implementerCredits"] for r in attempted]
    return {
        "attempted": len(attempted),
        "cleanReady": sum(r["clean"] for r in attempted),
        "cleanRate": round(sum(r["clean"] for r in attempted) / len(attempted), 3) if attempted else None,
        "questionsPerIssue": round(sum(r["questions"] for r in asked) / len(asked), 2) if asked else None,
        "failureClasses": classes,
        "implementerCredits": sum(credits) if credits and all(isinstance(c, int) for c in credits) else "unknown",
        "autoRetries": sum(r["autoRetries"] for r in attempted),
        "legacyIssues": sum(r["source"] == "legacy" for r in attempted),
        "awaitingAnswer": sum(r["awaitingAnswer"] for r in rows),
        "invalidReceipts": sum(r["invalidReceipts"] for r in rows),
        "issues": rows,
    }


def gh(args: list[str]):
    out = subprocess.run(["gh", *args], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def fetch(repo: str, since: str) -> list[dict]:
    issues = gh(["issue", "list", "--repo", repo, "--label", "squad", "--state", "all", "--limit", "500",
                 "--search", f"created:>={since}", "--json", "number"])
    result = []
    for item in issues:
        n = item["number"]
        timeline = gh(["api", "--paginate", "--slurp", f"repos/{repo}/issues/{n}/timeline?per_page=100"])
        timeline = [e for page in timeline for e in page]
        comments, events, merged = [], [], False
        for e in timeline:
            bot = (e.get("actor") or e.get("user") or {}).get("type") == "Bot"
            if e.get("event") == "commented":
                comments.append({"body": e.get("body", ""), "bot": bot})
            elif e.get("event") in ("labeled", "unlabeled"):
                events.append({"event": e["event"], "label": e.get("label", {}).get("name"), "bot": bot})
            elif e.get("event") == "cross-referenced":
                pr = (e.get("source") or {}).get("issue") or {}
                merged = merged or bool((pr.get("pull_request") or {}).get("merged_at"))
        result.append({"number": n, "comments": comments, "events": events, "prMerged": merged})
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("repos", nargs="*")
    ap.add_argument("--since", default="1970-01-01")
    ap.add_argument("--fixture")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if a.fixture:
        with open(a.fixture, encoding="utf-8") as f:
            issues = json.load(f)
    elif a.repos:
        issues = [i for r in a.repos for i in fetch(r, a.since)]
    else:
        ap.error("give at least one OWNER/REPO or --fixture")
    r = report(issues)
    if a.json:
        print(json.dumps(r, indent=2))
    else:
        rate = "n/a" if r["cleanRate"] is None else f"{r['cleanRate'] * 100:.0f} %"
        print(f"attempted issues: {r['attempted']} (legacy without receipts: {r['legacyIssues']})")
        print(f"ready without intervention: {r['cleanReady']} ({rate})")
        print(f"questions per issue: {r['questionsPerIssue']}; awaiting an answer: {r['awaitingAnswer']}")
        print(f"failure classes: {json.dumps(r['failureClasses'])}; automatic retries: {r['autoRetries']}")
        print(f"implementer credits: {r['implementerCredits']}; invalid receipts: {r['invalidReceipts']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
