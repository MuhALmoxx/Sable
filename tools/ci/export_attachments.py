#!/usr/bin/env python3
"""Export XCTest attachments (screenshots) from an .xcresult bundle with readable names.

Usage: export_attachments.py <bundle.xcresult> <output-dir>
Uses `xcrun xcresulttool export attachments` (Xcode 16+) and renames each exported file to its
attachment name (for example "01-launch.png") using the manifest the tool writes.
"""
import json
import os
import re
import subprocess
import sys


def walk(node, found):
    if isinstance(node, dict):
        exported = node.get("exportedFileName")
        if exported:
            found.append((exported, node.get("suggestedHumanReadableName") or exported))
        for value in node.values():
            walk(value, found)
    elif isinstance(node, list):
        for value in node:
            walk(value, found)


def main() -> int:
    bundle, out = sys.argv[1], sys.argv[2]
    if not os.path.isdir(bundle):
        print(f"no result bundle at {bundle}", file=sys.stderr)
        return 0
    os.makedirs(out, exist_ok=True)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", out], check=False)
    manifest = os.path.join(out, "manifest.json")
    if not os.path.exists(manifest):
        print("no manifest.json written", file=sys.stderr)
        return 0
    with open(manifest) as handle:
        found = []
        walk(json.load(handle), found)
    for exported, readable in found:
        source = os.path.join(out, exported)
        if not os.path.exists(source):
            continue
        base = re.sub(r"_[0-9A-F]{8}-[0-9A-F-]{27}", "", readable, flags=re.IGNORECASE)
        base = re.sub(r"[^A-Za-z0-9._-]+", "-", base).strip("-") or exported
        root, ext = os.path.splitext(base)
        # Xcode appends "_<attachment index>" to the suggested name ("01-library_0.png").
        root = re.sub(r"_\d+$", "", root) or root
        if not ext:
            ext = os.path.splitext(exported)[1]
        target = os.path.join(out, root + ext)
        counter = 2
        while os.path.exists(target):
            target = os.path.join(out, f"{root}-{counter}{ext}")
            counter += 1
        os.rename(source, target)
        print(f"{exported} -> {os.path.basename(target)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
