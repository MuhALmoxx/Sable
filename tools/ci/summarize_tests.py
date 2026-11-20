#!/usr/bin/env python3
"""Write a Markdown summary of an xcodebuild test log (for $GITHUB_STEP_SUMMARY)."""
import re
import sys

ICONS = {"passed": "✅", "failed": "❌", "skipped": "⏭️"}


def main() -> int:
    with open(sys.argv[1], errors="replace") as handle:
        lines = handle.read().splitlines()
    cases = []
    seen = set()
    for line in lines:
        match = re.search(r"Test Case '-\[(\S+) (\S+)\]' (passed|failed|skipped) \(([\d.]+) seconds\)", line)
        if match:
            key = (match.group(1), match.group(2), match.group(3))
            if key in seen:
                continue
            seen.add(key)
            cases.append((match.group(1).split(".")[-1], match.group(2), match.group(3), match.group(4)))
    skip_reasons = {}
    for line in lines:
        match = re.search(r"-\[\S+ (\S+)\] : Test skipped(?: - )?(.*)$", line)
        if match:
            skip_reasons[match.group(1)] = match.group(2).strip()[:160]
    errors = [line.strip() for line in lines if ": error: " in line][:30]
    metrics = [line.strip() for line in lines if "SABLE_METRIC" in line][:50]
    counts = {state: sum(1 for case in cases if case[2] == state) for state in ICONS}
    print(f"### Simulator tests: {counts['passed']} passed, {counts['failed']} failed, {counts['skipped']} skipped")
    if cases:
        print("| Suite | Test | Result | Seconds | Note |\n|---|---|---|---|---|")
        for suite, name, result, seconds in cases:
            note = skip_reasons.get(name, "") if result == "skipped" else ""
            note = note.replace("|", "\\|")
            print(f"| {suite} | {name} | {ICONS[result]} {result} | {seconds} | {note} |")
    if errors:
        print("\n**Errors**\n```\n" + "\n".join(errors) + "\n```")
    if metrics:
        print("\n**Metrics**\n```\n" + "\n".join(metrics) + "\n```")
    return 0


if __name__ == "__main__":
    sys.exit(main())
