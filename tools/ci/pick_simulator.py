#!/usr/bin/env python3
"""Pick (or create) an iPhone simulator for CI and print its UDID on stdout.

Usage:
  pick_simulator.py [--sdk-version 26.5] [--min-version 18.0] [--create-if-missing]
                    [--prefer "iPhone 17 Pro"] [--json FILE|-] [--github-output]

Reads `xcrun simctl list -j` (or --json FILE, "-" for stdin, for local testing) and chooses:
  1. a runtime: available iOS runtimes >= --min-version (the app's deployment target); prefers the
     runtime whose major.minor equals the selected Xcode's simulator SDK (--sdk-version, usually
     `xcrun --sdk iphonesimulator --show-sdk-version`), then the newest runtime with the same major
     version, then the newest runtime overall;
  2. a device on that runtime: --prefer / $SABLE_SIMULATOR_NAME if present, otherwise a 6.1"-class
     "iPhone N Pro" with the highest N, then the plain "iPhone N", then any iPhone;
  3. with --create-if-missing and no usable device on any runtime: `xcrun simctl create`s one from
     the runtime's supported iPhone device types.
Diagnostics go to stderr. With --github-output, also writes udid/name/runtime to $GITHUB_OUTPUT.
Exit status 1 when nothing usable exists.
"""
import argparse
import json
import os
import re
import subprocess
import sys


def log(message: str) -> None:
    print(message, file=sys.stderr)


def parse_version(text: str) -> tuple:
    parts = [int(p) for p in re.findall(r"\d+", text or "")[:3]]
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts)


def runtime_version_from_key(key: str) -> tuple:
    # com.apple.CoreSimulator.SimRuntime.iOS-26-5
    match = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?", key)
    if not match:
        return (0, 0, 0)
    return (int(match.group(1)), int(match.group(2)), int(match.group(3) or 0))


def device_rank(name: str) -> tuple:
    """Higher is better. Prefers 'iPhone N Pro' (not Max), then 'iPhone N', then other iPhones."""
    number_match = re.search(r"iPhone (\d+)", name)
    number = int(number_match.group(1)) if number_match else 0
    if re.fullmatch(r"iPhone \d+ Pro", name):
        family = 3
    elif re.fullmatch(r"iPhone \d+", name):
        family = 2
    elif "SE" in name or "mini" in name:
        family = 0
    else:
        family = 1
    return (family, number)


def load_simctl(json_path):
    if json_path == "-":
        return json.load(sys.stdin)
    if json_path:
        with open(json_path) as handle:
            return json.load(handle)
    output = subprocess.run(["xcrun", "simctl", "list", "-j"], check=True, capture_output=True, text=True).stdout
    return json.loads(output)


def ios_runtimes(data, min_version):
    """[(version tuple, identifier, runtime dict or None)] for available iOS runtimes."""
    found = {}
    for runtime in data.get("runtimes", []) or []:
        identifier = runtime.get("identifier", "")
        if "iOS" not in identifier and runtime.get("platform") != "iOS":
            continue
        if runtime.get("isAvailable") is False:
            continue
        version = parse_version(runtime.get("version", "")) if runtime.get("version") else runtime_version_from_key(identifier)
        found[identifier] = (version, identifier, runtime)
    # Device lists can mention runtimes the "runtimes" array lacks (older simctl JSON).
    for key in (data.get("devices") or {}).keys():
        if "iOS" in key and key not in found:
            found[key] = (runtime_version_from_key(key), key, None)
    return [entry for entry in found.values() if entry[0] >= min_version]


def order_runtimes(runtimes, sdk_version):
    def key(entry):
        version = entry[0]
        exact = sdk_version is not None and version[:2] == sdk_version[:2]
        same_major = sdk_version is not None and version[0] == sdk_version[0]
        return (1 if exact else 0, 1 if same_major else 0, version)
    return sorted(runtimes, key=key, reverse=True)


def pick_device(devices, preferred):
    usable = [d for d in devices if d.get("isAvailable", True) and d.get("name", "").startswith("iPhone")]
    if not usable:
        return None
    if preferred:
        for device in usable:
            if device.get("name") == preferred:
                return device
    usable.sort(key=lambda d: (device_rank(d.get("name", "")), d.get("state") == "Booted"), reverse=True)
    return usable[0]


def create_device(runtime_identifier, runtime, data, preferred):
    device_types = []
    if runtime and runtime.get("supportedDeviceTypes"):
        device_types = runtime["supportedDeviceTypes"]
    else:
        device_types = data.get("devicetypes", []) or []
    iphones = [t for t in device_types if t.get("productFamily", "iPhone") == "iPhone" and t.get("name", "").startswith("iPhone")]
    if not iphones:
        return None
    chosen = None
    if preferred:
        chosen = next((t for t in iphones if t.get("name") == preferred), None)
    if chosen is None:
        iphones.sort(key=lambda t: device_rank(t.get("name", "")), reverse=True)
        chosen = iphones[0]
    name = f"Sable CI {chosen['name']}"
    log(f"creating simulator '{name}' ({chosen['identifier']}) on {runtime_identifier}")
    udid = subprocess.run(["xcrun", "simctl", "create", name, chosen["identifier"], runtime_identifier],
                          check=True, capture_output=True, text=True).stdout.strip()
    return {"udid": udid, "name": name}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk-version", default=None)
    parser.add_argument("--min-version", default="18.0")
    parser.add_argument("--create-if-missing", action="store_true")
    parser.add_argument("--prefer", default=os.environ.get("SABLE_SIMULATOR_NAME") or None)
    parser.add_argument("--json", default=None)
    parser.add_argument("--github-output", action="store_true")
    args = parser.parse_args()

    sdk_version = parse_version(args.sdk_version) if args.sdk_version else None
    data = load_simctl(args.json)
    runtimes = order_runtimes(ios_runtimes(data, parse_version(args.min_version)), sdk_version)
    if not runtimes:
        log(f"no iOS simulator runtime >= {args.min_version} is installed")
        return 1

    devices_by_runtime = data.get("devices") or {}
    choice = None
    for version, identifier, runtime in runtimes:
        device = pick_device(devices_by_runtime.get(identifier, []), args.prefer)
        if device:
            choice = (device, identifier, version)
            break
    if choice is None and args.create_if_missing:
        for version, identifier, runtime in runtimes:
            try:
                device = create_device(identifier, runtime, data, args.prefer)
            except subprocess.CalledProcessError as error:
                log(f"simctl create failed on {identifier}: {error.stderr}")
                device = None
            if device:
                choice = (device, identifier, version)
                break
    if choice is None:
        log("no iPhone simulator available (try --create-if-missing)")
        return 1

    device, identifier, version = choice
    runtime_label = ".".join(str(v) for v in version[:2])
    log(f"picked {device['name']} on iOS {runtime_label} ({device['udid']})"
        + (f"; SDK {args.sdk_version}" if args.sdk_version else ""))
    print(device["udid"])
    if args.github_output and os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
            handle.write(f"udid={device['udid']}\nname={device['name']}\nruntime=iOS {runtime_label}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
