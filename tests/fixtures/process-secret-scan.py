#!/usr/bin/env python3
from pathlib import Path
import re
import sys

FORBIDDEN_NAMES = (
    b"COPILOT_GITHUB_TOKEN=",
    b"GITHUB_TOKEN=",
    b"GH_TOKEN=",
    b"COPILOT_PAT=",
)
PAT_PATTERN = re.compile(rb"github_pat_[A-Za-z0-9_]+")
findings: list[str] = []

for process_dir in Path("/proc").iterdir():
    if not process_dir.name.isdigit():
        continue

    try:
        environ = (process_dir / "environ").read_bytes()
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        environ = b""
    for name in FORBIDDEN_NAMES:
        if name in environ:
            findings.append(f"pid-{process_dir.name}:environment:{name[:-1].decode()}")

    try:
        command_line = (process_dir / "cmdline").read_bytes()
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        command_line = b""
    if PAT_PATTERN.search(command_line):
        findings.append(f"pid-{process_dir.name}:command-line:PAT-value")

if findings:
    print("\n".join(findings), file=sys.stderr)
    raise SystemExit(1)

print("Active agent process secret isolation: PASS")
