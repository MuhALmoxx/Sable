#!/usr/bin/env python3
"""Write a Markdown summary of an xcodebuild test log (for $GITHUB_STEP_SUMMARY)."""
import re
import sys


def main() -> int:
    with open(sys.argv[1], errors="replace") as handle:
        lines = handle.read().splitlines()
    cases = []
    for line in lines:
        match = re.search(r"Test Case '-\[\S+ (\S+)\]' (passed|failed) \(([\d.]+) seconds\)", line)
        if match:
            cases.append((match.group(1), match.group(2), match.group(3)))
    errors = [line.strip() for line in lines if ": error: " in line][:30]
    metrics = [line.strip() for line in lines if "SABLE_METRIC" in line][:50]
    passed = sum(1 for case in cases if case[1] == "passed")
    failed = sum(1 for case in cases if case[1] == "failed")
    print(f"### Simulator UI tests: {passed} passed, {failed} failed")
    if cases:
        print("| Test | Result | Seconds |\n|---|---|---|")
        for name, result, seconds in cases:
            print(f"| {name} | {'✅' if result == 'passed' else '❌'} {result} | {seconds} |")
    if errors:
        print("\n**Errors**\n```\n" + "\n".join(errors) + "\n```")
    if metrics:
        print("\n**Metrics**\n```\n" + "\n".join(metrics) + "\n```")
    return 0


if __name__ == "__main__":
    sys.exit(main())
