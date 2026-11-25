#!/usr/bin/env python3
"""Prepare Curator diagnostics and validate a staged candidate patch."""

import argparse
from html import unescape
import json
from pathlib import Path
import re
import subprocess
import sys
import unicodedata

SOURCE_ROOTS = (
    "app/Triptych/", "app/TriptychTests/", "app/TriptychJITHelper/",
    "app/MacAppsKit/", "app/WinVMHost/",
    "engines/gesso/", "engines/macapps/", "engines/winvm/",
)
EXCLUDED_DIRS = {"vendor", "third_party", "upstreams", "scripts", "tools", "build", "patches"}
MAX_PATCH_BYTES = 512 * 1024
SOURCE_SUFFIXES = (".swift", ".c", ".h", ".m", ".mm", ".s", ".S")


def diagnostics(issue, triage_source):
    body = issue.get("body") or ""
    if "pull_request" in issue or not isinstance(body, str) or len(body) > 65_536:
        raise ValueError("expected a bounded issue report")

    body = "".join(
        char for char in unescape(body)
        if unicodedata.category(char) != "Cf"
        and not 0xE0000 <= ord(char) <= 0xE007F
        and not 0xFE00 <= ord(char) <= 0xFE0F
        and not 0xE0100 <= ord(char) <= 0xE01EF
        and char != "\u034f"
    )
    body = re.sub(r"<!--.*?(?:-->|\Z)", "", body, flags=re.S)
    body = re.sub(r"<picture\b[^>]*>.*?(?:</picture\s*>|\Z)", "", body, flags=re.I | re.S)
    body = re.sub(r"<[^<>]*>", "", body)
    section = re.search(r"^## Diagnostics[ \t]*\r?\n(.*?)(?=^#{1,6} |\Z)", body, re.M | re.S)
    if not section:
        raise ValueError("missing Curator Diagnostics section")

    known = set(re.findall(r'\bRule\("([a-z0-9-]+)"', triage_source))
    findings = []
    for line in section[1].splitlines():
        match = re.fullmatch(r"([a-z0-9-]+) \| ([a-zA-Z0-9-]{1,24}) \| (previous|current) run", line)
        if match and match[1] in known:
            findings.append({"signature": match[1], "previous_run": match[3] == "previous"})
    if not findings:
        raise ValueError("no recognized Curator signature")
    return {"findings": findings[:8]}


def validate(raw_diff, numstat):
    entries = raw_diff.split(b"\0")[:-1]
    if not entries or len(entries) % 2:
        raise ValueError("patch is empty")
    for header, raw_path in zip(entries[::2], entries[1::2]):
        old_mode, new_mode, _, _, operation = header.split()
        path = raw_path.decode("ascii")
        expected_modes = {b"M": (b":100644", b"100644"), b"A": (b":000000", b"100644")}
        if (
            (old_mode, new_mode) != expected_modes.get(operation)
            or not path.startswith(SOURCE_ROOTS)
            or not path.endswith(SOURCE_SUFFIXES)
            or not re.fullmatch(r"[A-Za-z0-9_+./ -]+", path)
            or any(part.startswith(".") for part in path.split("/"))
            or any(part.lower() in EXCLUDED_DIRS for part in path.split("/"))
        ):
            raise ValueError(f"forbidden patch entry {path!r}")
    if any(row.startswith(b"-\t") for row in numstat.split(b"\0")):
        raise ValueError("binary patches are forbidden")


def apply_patch(path):
    if path.stat().st_size > MAX_PATCH_BYTES:
        raise ValueError("candidate patch exceeds 512 KiB")
    subprocess.run(["git", "diff", "--cached", "--quiet", "HEAD"], check=True)
    subprocess.run(
        ["git", "apply", "--index", "--whitespace=error", "--", str(path.resolve())],
        check=True,
    )
    diff = ["git", "diff", "--cached", "--no-renames", "--no-ext-diff", "--no-textconv", "-z", "HEAD"]
    validate(subprocess.check_output([*diff, "--raw"]), subprocess.check_output([*diff, "--numstat"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    prepare = subcommands.add_parser("diagnostics")
    prepare.add_argument("event", choices=("tracker", "private"))
    apply = subcommands.add_parser("apply")
    apply.add_argument("patch", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "diagnostics":
            payload = json.load(sys.stdin)
            issue = payload["issue"] if args.event == "private" else payload
            source = Path("app/Triptych/Curator/Triage.swift").read_text(encoding="utf-8")
            print(json.dumps(diagnostics(issue, source)))
        else:
            apply_patch(args.patch)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"Curator autofix: {error}")


if __name__ == "__main__":
    main()
