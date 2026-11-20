#!/usr/bin/env python3
"""Pick an available iPhone simulator from `xcrun simctl list devices available -j` (stdin).

Preference: newest iOS runtime, then a "Pro" (not Max) iPhone with the highest model number,
then any iPhone. Prints the UDID.
"""
import json
import re
import sys


def runtime_version(key: str) -> tuple:
    match = re.search(r"iOS-(\d+)-(\d+)", key)
    return (int(match.group(1)), int(match.group(2))) if match else (0, 0)


def model_rank(name: str) -> tuple:
    number = re.search(r"iPhone (\d+)", name)
    n = int(number.group(1)) if number else 0
    is_pro = name.endswith(" Pro")
    return (1 if is_pro else 0, n)


def main() -> int:
    data = json.load(sys.stdin)
    candidates = []
    for runtime, devices in data.get("devices", {}).items():
        if "iOS" not in runtime:
            continue
        for device in devices:
            if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
                candidates.append((runtime_version(runtime), model_rank(device["name"]), device["udid"], device["name"]))
    if not candidates:
        print("no iPhone simulator available", file=sys.stderr)
        return 1
    candidates.sort(reverse=True)
    best = candidates[0]
    print(f"picked {best[3]} on iOS {best[0][0]}.{best[0][1]}", file=sys.stderr)
    print(best[2])
    return 0


if __name__ == "__main__":
    sys.exit(main())
