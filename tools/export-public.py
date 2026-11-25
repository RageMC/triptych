#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds the public Triptych tree from this repository's HEAD, scrubbed and leak-scanned.

    python3 tools/export-public.py [--out DIR] [--rev REV]

The output is a fresh git repository with one commit (no private history) whose submodules are
gitlinks to the public upstream projects. It never pushes: making anything public is the owner's step
((private notes)). The run fails (exit 1) and commits nothing if any check fails.

What it guarantees, each checked after writing:
  - no CodeWeavers, Valve, Apple or Windows binaries or disk/firmware images (no binary file at all
    except the allowlisted Triptych images; nothing whose path names those vendors' products as data)
  - no keys, tokens or private keys
  - no private paths, user names, real name, emails, host/device names, UDIDs, LAN addresses or ~/Downloads
    file names; no metadata in images
  - nothing from docs/research, internal checklists or local tooling
  - CREDITS.md names every submodule, vendored and third-party library, plus Perl, Qwen and llama.cpp
It also writes RELEASE-CHECKLIST.md into the tree and a private report next to it.
"""
import argparse
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOME = Path.home()
NOREPLY = "24841174+RageMC@users.noreply.github.com"

# Never exported, whatever they contain.
EXCLUDE = [
    r"^docs/research/", r"^docs/PUBLIC-CHECKLIST\.md$", r"^docs/GO-PUBLIC-CHECKLIST\.md$",
    # Internal logs, plans and research write-ups: dated, partly superseded, and they name local tools and paths.
    r"^docs/(PROGRESS|REVAMP|ON-DEVICE-AI|RESEARCH|CURATOR-AUTOFIX)\.md$", r"^docs/plans/",
    r"^(unpublished screenshot)",          # Windows Setup, CrossOver and macOS windows from testing
    r"^docs/screenshots/macapp-", r"^engines/macapps/host/proof/",
    r"^tools/wintrace/",
    r"(^|/)\.claude/", r"(^|/)\.dev\.vars$", r"(^|/)\.env(\..*)?$", r"(^|/)node_modules/", r"(^|/)\.wrangler/",
    r"(?i)give-to-claude",
]
# Binary files allowed through: Triptych's own icon, brand art and Linux desktop screenshots.
BINARY_ALLOW = [
    r"^app/Triptych/Assets\.xcassets/.*\.png$", r"^docs/brand/.*\.(png|svg)$",
    r"^docs/screenshots/[^/]+\.png$", r"^engines/linux-desktop/proof/.*\.png$",
]
# Extensions that are never source: executables, libraries, disk/firmware images, archives, installers.
BINARY_EXT = {".dll", ".exe", ".sys", ".msi", ".cab", ".wim", ".esd", ".iso", ".img", ".vhd", ".vhdx", ".qcow2",
              ".dmg", ".pkg", ".ipsw", ".ipa", ".app", ".dylib", ".so", ".a", ".o", ".framework", ".metallib",
              ".bin", ".fd", ".rom", ".efi", ".zip", ".7z", ".tar", ".gz", ".zst", ".xz", ".gguf", ".mlmodel",
              ".mlpackage", ".fmadapter", ".car", ".nib", ".heic", ".jpg", ".jpeg", ".mov", ".mp4"}
VENDOR_DATA = re.compile(r"(?i)(crossover|codeweavers|d3dmetal|gptk|steam|valve|avpbooter|windows ?1[01]|win1[01])"
                         r".*\.(png|jpe?g|dll|exe|dylib|bin|img|iso|wim|esd|dmg|pkg|plist|car|nib|zip)$")

LEAK = {
    "github token": r"\bgh[pousr]_[A-Za-z0-9]{30,}", "github pat": r"\bgithub_pat_\w{30,}",
    "anthropic key": r"\bsk-ant-[\w-]{20,}", "openai key": r"\bsk-(?:proj-)?[A-Za-z0-9]{32,}",
    "google key": r"\bAIza[0-9A-Za-z_-]{35}\b", "aws key": r"\bAKIA[0-9A-Z]{16}\b",
    "slack token": r"\bxox[abpr]-[A-Za-z0-9-]{20,}", "private key": r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----\s*\n\s*[A-Za-z0-9+/]{40}",
    "bearer token": r"\bBearer [A-Za-z0-9._-]{40,}", "gmail": r"[\w.+-]+@gmail\.com",
    "mac hostname": r"[\w.-]+\.local>", "tailnet": r"[\w.-]+\.ts\.net\b",
    # Not flagged: QEMU's user network (10.0.2.x) and StikJIT/LocalDevVPN's tunnel (10.7.0.x, 10.7.1.x), the same
    # on every machine.
    "lan ip": r"\b(?:192\.168|10\.(?!0\.2\.|7\.[01]\.)\d{1,3}|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b",
    "personal email": r"[\w.+-]+@(?:icloud|me|mac|outlook|hotmail|live|yahoo|proton(?:mail)?|pm)\.(?:com|me)\b",
    "home path": r"/Users/(?!Shared/)(?!runner/)[a-z][\w.-]+/(?:src|Downloads|Desktop|Documents|Library)/",
    "device udid": r"\b0000[0-9A-F]{4}-[0-9A-F]{16}\b",
}
# Names in ~/Downloads that are generic (the app's own log names, a vendor's standard installer name), not personal.
DOWNLOADS_ALLOW = re.compile(r"(?i)(\.log$|^SteamSetup\.exe$|^triptych)")
# Home folders are caught through private_terms() (the owner's home path and user name), not a generic
# /Users/<name>/ pattern: tests and vendored code use made-up or upstream authors' paths on purpose.
# Unit tests that prove the scrubber removes fake tokens; their samples are synthetic and short-lived by design.
LEAK_ALLOW = {("app/TriptychTests/LogScrubberTests.swift", "bearer token"),
              ("app/TriptychTests/LogScrubberTests.swift", "github token"),
              ("app/TriptychTests/LogScrubberTests.swift", "github pat"),
              ("app/TriptychTests/LogScrubberTests.swift", "lan ip"),
              ("app/TriptychTests/GitHubReporterTests.swift", "github token"),
              ("app/TriptychTests/LogScrubberTests.swift", "personal email"),
              ("app/TriptychTests/LogScrubberTests.swift", "gmail"),
              ("app/TriptychTests/LogScrubberTests.swift", "home path"),
              ("app/TriptychTests/LogScrubberTests.swift", "device udid"),
              ("app/Vendor/SwiftTerm/Buffer.swift", "home path"),  # upstream author's debug-dump path
              ("engines/gesso/third_party/mbedtls", "private key")}
# Vendored code and licence texts keep their upstream authors' contact addresses and spec section numbers.
for _vendored in ("engines/gesso/third_party/", "app/Vendor/", "engines/gesso/ios/Henge/Resources/legal/"):
    LEAK_ALLOW |= {(_vendored, "gmail"), (_vendored, "personal email"), (_vendored, "lan ip")}

REQUIRED_CREDITS = ["Perl", "Qwen", "llama.cpp", "SwiftTerm", "fflate", "QEMU", "EDK2", "Wine", "FEX"]


def git(*args, cwd=ROOT, check=True, **kw):
    return subprocess.run(["git", "-C", str(cwd), *args], check=check, capture_output=True, **kw)


def private_terms():
    """Strings that identify the owner, read locally and never printed."""
    terms = {str(HOME), HOME.name}
    for key in ("user.email", "user.name"):
        for scope in ("--global", "--local"):
            r = git("config", scope, key, check=False, text=True)
            terms |= {r.stdout.strip()} if r.returncode == 0 else set()
    real = subprocess.run(["id", "-F"], capture_output=True, text=True).stdout.strip()
    terms |= {real, real.split()[-1]} if real else set()
    terms |= machine_terms()
    terms -= {NOREPLY, "RageMC"}  # the public GitHub identity the project is published under
    return {t for t in terms if t and len(t) >= 4}


def run_text(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def machine_terms():
    """This Mac's and its devices' identities: host names, Simulator and device UDIDs, paired device names, and
    the file names in ~/Downloads (they say what was tested and where). Read locally, never printed."""
    terms = {run_text("scutil", "--get", k) for k in ("ComputerName", "LocalHostName", "HostName")}
    terms.add(run_text("hostname", "-s"))
    try:
        sims = json.loads(run_text("xcrun", "simctl", "list", "devices", "-j") or "{}").get("devices", {})
        terms |= {d.get("udid", "") for group in sims.values() for d in group}
    except ValueError:
        pass
    out = HOME / ".cache" / "triptych-export-devices.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    run_text("xcrun", "devicectl", "list", "devices", "--quiet", "--json-output", str(out))
    try:
        for d in json.loads(out.read_text()).get("result", {}).get("devices", []):
            hw, props = d.get("hardwareProperties", {}), d.get("deviceProperties", {})
            terms |= {d.get("identifier", ""), hw.get("udid", ""), hw.get("serialNumber", "")}
            if hw.get("reality") == "physical":
                name = props.get("name", "")
                terms |= {name, name.replace("\u2019", "'")}
    except (OSError, ValueError):
        pass
    finally:
        out.unlink(missing_ok=True)
    downloads = HOME / "Downloads"
    if downloads.is_dir():
        terms |= {n for n in os.listdir(downloads) if len(n) >= 10 and not n.startswith(".")
                  and not DOWNLOADS_ALLOW.search(n)}
    # A default name ("MacBook Pro", "iPad") says nothing about the owner and matches upstream device tables.
    generic = re.compile(r"(?i)^(?:(?:mac|macbook|imac|ipad|iphone|pro|air|max|mini|studio|local|s)\W*|\d+\W*)+$")
    return {t for t in terms if t and not generic.match(t)}


def scrub(text, terms):
    text = text.replace(str(HOME), "~")
    for t in sorted(terms, key=len, reverse=True):
        text = text.replace(t, "<private>")
    # Emails and addresses are not rewritten: upstream licences carry their authors' addresses and the code needs
    # fixed ones (QEMU's 10.0.2.x, StikJIT/LocalDevVPN's 10.7.x). Anything else fails the scan below instead.
    text = re.sub(r"(DEVELOPMENT_TEAM\s*[:=]\s*\"?)[A-Z0-9]{10}\b", r"\1YOUR_TEAM_ID", text)
    # Markdown images that point at files the export leaves out become a plain note.
    text = re.sub(r"!\[([^\]]*)\]\(([^)]*(unpublished screenshot)[^)]*|[^)]*macapp-[^)]*\.png)\)", r"(screenshot not published: \1)", text)
    # Links and paths to files the export leaves out: keep the words, drop the dead target.
    text = re.sub(r"(?<!!)\[([^\]]*)\]\((?:\.\./)?(?:docs/)?(unpublished screenshot)[^)]*\)", r"\1 (not published)", text)
    text = re.sub(r"`?(?:docs/)?(unpublished screenshot)[\w.*{},-]*`?", "(unpublished screenshot)", text)
    text = re.sub(r"`?docs/(?:research/[\w.*-]+|(?:GO-)?PUBLIC-CHECKLIST\.md|PROGRESS\.md|REVAMP\.md|ON-DEVICE-AI\.md|"
                  r"RESEARCH\.md|CURATOR-AUTOFIX\.md|plans/[\w.-]+)`?", "(private notes)", text)
    return text


def matches(path, patterns):
    return any(re.search(p, path) for p in patterns)


def is_binary(data):
    return b"\0" in data[:8192]


def export(rev, out, terms):
    archive = git("archive", "--format=tar", rev).stdout
    kept, dropped = [], []
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar.getmembers():
            path = member.name
            if member.isdir():
                continue
            if member.issym():  # stray symlinks (old submodule paths) point at this Mac
                dropped.append((path, "symlink"))
                continue
            if not member.isfile():
                continue
            data = tar.extractfile(member).read()
            ext = Path(path).suffix.lower()
            reason = None
            if matches(path, EXCLUDE):
                reason = "excluded path"
            elif VENDOR_DATA.search(path):
                reason = "vendor data file"
            elif (is_binary(data) or ext in BINARY_EXT) and not matches(path, BINARY_ALLOW):
                reason = "binary"
            if reason:
                dropped.append((path, reason))
                continue
            dest = out / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            if is_binary(data):
                dest.write_bytes(data)
            else:
                dest.write_text(scrub(data.decode("utf-8", errors="replace"), terms))
            if member.mode & 0o111:
                dest.chmod(0o755)
            kept.append(path)
    return kept, dropped


def submodules(rev):
    """Each .gitmodules entry with the commit to pin: the gitlink at REV, else the local checkout's HEAD."""
    mods = git("config", "-f", ".gitmodules", "--get-regexp", r"submodule\..*\.(path|url)", text=True).stdout
    entries = {}
    for line in mods.splitlines():
        key, value = line.split(" ", 1)
        name, field = key[len("submodule."):].rsplit(".", 1)
        entries.setdefault(name, {})[field] = value
    tree = git("ls-tree", rev, "upstreams/", text=True).stdout
    modes = {l.split("\t")[1]: l.split()[:3] for l in tree.splitlines()}
    for e in entries.values():
        mode, _, sha = modes.get(e["path"], ["", "", ""])
        e["local"] = 0
        if mode != "160000":
            # The checkout may carry local commits that exist only on this Mac; pin the newest upstream
            # commit under them (Triptych's own changes ship as engines/*/patches, not in the submodule).
            sub = (ROOT / e["path"]).resolve()
            sha = ""
            if sub.exists():
                local = git("rev-list", "--first-parent", "HEAD", "--not", "--remotes", cwd=sub,
                            check=False, text=True).stdout.split()
                base = f"{local[-1]}^" if local else "HEAD"
                r = git("rev-parse", "--verify", "-q", base, cwd=sub, check=False, text=True)
                if r.returncode != 0:  # shallow clone or a remote other than the .gitmodules URL: pin HEAD
                    r = git("rev-parse", "HEAD", cwd=sub, check=False, text=True)
                    local = []
                sha = r.stdout.strip() if r.returncode == 0 else ""
                e["local"] = len(local)
        e["sha"] = sha
        e["url"] = e["url"] if e["url"].startswith("https://") else ""
    return list(entries.values())


def png_metadata(data):
    """Chunk types that carry text, EXIF, time or colour-profile names (profiles name the display they came from)."""
    found, i = [], 8
    while i + 8 <= len(data):
        n = int.from_bytes(data[i:i + 4], "big")
        kind = data[i + 4:i + 8].decode("latin-1")
        if kind in ("tEXt", "zTXt", "iTXt", "eXIf", "tIME", "iCCP"):
            found.append(kind)
        i += 12 + n
    return sorted(set(found))


def scan(out, terms):
    hits = []
    for p in sorted(out.rglob("*")):
        if ".git" in p.relative_to(out).parts or not p.is_file():
            continue
        rel = str(p.relative_to(out))
        data = p.read_bytes()
        if matches(rel, EXCLUDE):
            hits.append(f"{rel}: excluded path present")
        if is_binary(data):
            if data[:8] == b"\x89PNG\r\n\x1a\n":
                meta = png_metadata(data)
                if meta:
                    hits.append(f"{rel}: image metadata ({', '.join(meta)}); strip it")
            if any(t.encode() in data for t in terms):
                hits.append(f"{rel}: private term in binary")
            if not matches(rel, BINARY_ALLOW):
                hits.append(f"{rel}: binary outside the allowlist")
            if data[:4] in (b"MZ\x90\x00", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\x7fELF"):
                hits.append(f"{rel}: executable")
            continue
        text = data.decode("utf-8", errors="replace")
        if any(t in text for t in terms):
            hits.append(f"{rel}: private term")
        for name, pattern in LEAK.items():
            if any(rel.startswith(a) and name == n for a, n in LEAK_ALLOW):
                continue
            m = re.search(pattern, text)
            if m:
                hits.append(f"{rel}: {name}")
    return hits


def credits_gaps(out, subs):
    text = (out / "CREDITS.md").read_text() if (out / "CREDITS.md").exists() else ""
    lower = text.lower()
    gaps = [f"CREDITS.md lacks {n}" for n in REQUIRED_CREDITS if n.lower() not in lower]
    for e in subs:
        repo = e["url"].rstrip("/").removesuffix(".git").rsplit("/", 1)[-1]
        if repo and repo.lower() not in lower:
            gaps.append(f"CREDITS.md lacks submodule {repo}")
    for base in ("app/Vendor", "engines/gesso/third_party"):
        d = out / base
        for lib in sorted(x.name for x in d.iterdir() if x.is_dir()) if d.exists() else []:
            stem = lib.lower().replace("lib", "", 1) if lib.lower().startswith("lib") else lib.lower()
            if lib.lower() not in lower and stem not in lower:
                gaps.append(f"CREDITS.md lacks {base}/{lib}")
    if not (out / "LICENSE").exists():
        gaps.append("LICENSE missing")
    return gaps


def release_checklist(out, kept, dropped, subs, rev_sha):
    by_reason = {}
    for _, reason in dropped:
        by_reason[reason] = by_reason.get(reason, 0) + 1
    lines = [
        "# Release checklist", "",
        f"Generated by `tools/export-public.py` from commit `{rev_sha[:12]}` on {time.strftime('%Y-%m-%d')}.", "",
        "## Checked automatically (the export fails if any of these fail)", "",
        f"- [x] {len(kept)} files exported; {len(dropped)} left out "
        f"({', '.join(f'{v} {k}' for k, v in sorted(by_reason.items())) or 'none'}).",
        "- [x] No binaries except Triptych's own icon, brand art and Linux desktop screenshots; no executables.",
        "- [x] No CodeWeavers, Valve, Apple or Windows binaries, firmware or disk images.",
        "- [x] No keys or tokens (GitHub, OpenAI, Anthropic, Google, AWS, Slack, PEM private keys, bearer tokens).",
        "- [x] No private paths, user names, real name, emails, host or device names, Simulator or device UDIDs, "
        "LAN addresses or ~/Downloads file names; screenshots carry no text, EXIF or time metadata.",
        "- [x] Nothing from `docs/research/`, internal checklists or local tooling.",
        "- [x] CREDITS.md names every submodule, vendored library and model, including Perl, Qwen and llama.cpp; LICENSE present.",
        "", "## Submodules (pinned as gitlinks)", "",
    ]
    for e in subs:
        note = (f" The local checkout has {e['local']} more commit(s) that are not upstream; confirm Triptych "
                "ships them as patches or in-tree." if e.get("local") else "")
        lines.append(f"- [ ] `{e['path']}` → {e['url']} at `{e['sha'][:12] or 'MISSING'}`: confirm the commit "
                     f"is public upstream.{note}")
    lines += [
        "", "## Before each release (manual)", "",
        "- [ ] Full test suite green on an iPad Simulator: `xcodebuild test -project app/Triptych.xcodeproj -scheme Triptych`.",
        "- [ ] Curator relay tests: `cd tools/curator-relay && npm ci && npx vitest run`; local end to end: `tools/curator-relay/e2e-local.sh`.",
        "- [ ] `app/project.yml` `TriptychReportRelayURL` set to the deployed relay (https) and `TriptychIssueRepo` to the public tracker.",
        "- [ ] Any IPA attached to the release was built by `scripts/package-ipa.sh`, which strips debug maps and refuses "
        "to package if the home path or user name is left in the bundle.",
        "- [ ] Release notes mention that Windows, macOS and game files are supplied by the user; none ship with Triptych.",
    ]
    (out / "RELEASE-CHECKLIST.md").write_text("\n".join(lines) + "\n")


def commit(out, subs):
    g = lambda *a: git(*a, cwd=out)
    g("init", "-q", "-b", "main")
    g("config", "user.name", "RageMC")
    g("config", "user.email", NOREPLY)
    g("add", "-A")
    for e in subs:
        if e["sha"] and e["url"]:
            g("update-index", "--add", "--cacheinfo", f"160000,{e['sha']},{e['path']}")
    g("commit", "-q", "-m", "Triptych public source")
    return git("rev-parse", "HEAD", cwd=out, text=True).stdout.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default=str(HOME / "src/triptych-public"))
    ap.add_argument("--rev", default="HEAD")
    args = ap.parse_args()
    out = Path(args.out).expanduser().resolve()
    if out == ROOT or ROOT in out.parents:
        sys.exit("--out must be outside the repository")
    if out.exists():
        if not (out / ".git").exists() and not (out / ".triptych-export").exists() and any(out.iterdir()):
            sys.exit(f"{out} exists and is not an earlier export; choose another --out")
        shutil.rmtree(out)
    out.mkdir(parents=True)
    (out / ".triptych-export").write_text("marks a tools/export-public.py output; removed on success\n")
    rev_sha = git("rev-parse", args.rev, text=True).stdout.strip()
    terms = private_terms()
    kept, dropped = export(args.rev, out, terms)
    subs = submodules(args.rev)
    gm = "".join(f'[submodule "{e["path"]}"]\n\tpath = {e["path"]}\n\turl = {e["url"]}\n' for e in subs if e["url"])
    (out / ".gitmodules").write_text(gm)
    release_checklist(out, kept, dropped, subs, rev_sha)
    problems = scan(out, terms) + credits_gaps(out, subs)
    problems += [f"{e['path']}: no commit to pin" for e in subs if not e["sha"]]
    report = out.parent / (out.name + "-export-report.txt")
    report.write_text("\n".join([f"export of {rev_sha} at {time.strftime('%Y-%m-%d %H:%M')}", "", "LEFT OUT:"]
                                + [f"  {p}  ({r})" for p, r in dropped] + ["", "PROBLEMS:"]
                                + [f"  {p}" for p in problems]) + "\n")
    if problems:
        print(f"EXPORT FAILED: {len(problems)} problem(s); nothing committed. Details: {report}")
        for p in problems[:40]:
            print("  " + p)
        sys.exit(1)
    (out / ".triptych-export").unlink()
    head = commit(out, subs)
    print(f"export ok: {len(kept)} files, {len(dropped)} left out, leak scan clean, credits complete")
    print(f"tree: {out} (commit {head[:12]}, not pushed)")
    print(f"checklist: {out / 'RELEASE-CHECKLIST.md'}")
    print(f"report (private, outside the tree): {report}")


if __name__ == "__main__":
    main()
