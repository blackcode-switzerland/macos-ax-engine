#!/usr/bin/env python3
"""Print one table for all trial modes and decide the job result.

The job passes when the mode `direct` (the probe started straight from the
workflow's shell step) passed every core check. The other modes are reported,
not judged: they show how the permission behaves for other ways of starting.
"""
import json
import os
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "out"
modes = ["direct", "child-of-python", "bundle-direct", "bundle-open"]
lines = []
verdicts = {}

for mode in modes:
    path = os.path.join(root, mode, "results.json")
    if not os.path.exists(path):
        verdicts[mode] = "NO RESULT"
        lines.append(f"| {mode} | NO RESULT | the probe wrote no results (did not start, or was stopped) |")
        continue
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    verdicts[mode] = data["verdict"]
    for check in data["checks"]:
        detail = check["detail"].replace("|", "/").replace("\n", " ")
        lines.append(f"| {mode} | {check['status']} {check['name']} | {detail} |")

table = ["| mode | check | detail |", "| --- | --- | --- |"] + lines
summary = ["## Accessibility trial", ""]
summary += [f"- **{mode}**: {verdicts[mode]}" for mode in modes]
summary += [""] + table
text = "\n".join(summary) + "\n"
print(text)

target = os.environ.get("GITHUB_STEP_SUMMARY")
if target:
    with open(target, "a", encoding="utf-8") as handle:
        handle.write(text)

sys.exit(0 if verdicts.get("direct") == "PASS" else 1)
