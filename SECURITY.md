# Security Policy

## Scope

Triptych runs untrusted guest operating systems and executables (Windows, macOS, Mac apps, Linux, and x86 PC images) inside an iOS/iPadOS app sandbox with JIT compilation enabled, and includes an on-device diagnostic reporter (**Curator**) and anonymous Cloudflare reporting relay.

Security issues of particular interest include:

- **VM / Translation Layer Escape:** Guest-to-host memory corruption or arbitrary code execution outside the guest bounds in `engines/gesso/`, `engines/winvm/`, `engines/macapps/`, `engines/linux/`, or `engines/x86pc/`.
- **Archive & Package Extraction Vulnerabilities:** Path traversal, symlink escapes, or out-of-bounds memory access when parsing `.dmg`, `.pkg`, `.zip`, `.tar.zst`, or `.ipa` files (`engines/macapps/dmg/`, `fakefs` import).
- **Curator & Log Scrubber Leaks:** PII, credentials, tokens, or local host/container paths bypassing `LogScrubber.swift` or `tools/curator-relay/report.js`.
- **Curator Fix Packs & Autofix Pipeline:** Signature verification bypasses in Curve25519-signed fix packs (`CuratorFixPack.swift`) or command/prompt injection in `tools/curator-autofix.py` and `.github/workflows/curator-autofix.yml`.
- **Relay Abuse / Authentication:** Bypasses of proof-of-work (`X-Curator-Challenge` / `X-Curator-Nonce`), rate limiting, or ZIP validation in `tools/curator-relay/`.

## Reporting a Vulnerability

**Please do not report security vulnerabilities in public GitHub issues.**

1. **GitHub Private Vulnerability Reporting (Preferred):**
   Use the [**Report a vulnerability**](https://github.com/RageMC/triptych/security/advisories/new) button on the repository's **Security** tab to open a private security advisory directly with the maintainer.
2. **What to Include:**
   - Affected component (`engines/gesso`, `engines/winvm`, `engines/macapps`, `app/Triptych/Curator`, `tools/curator-relay`, etc.) and commit hash.
   - A minimal reproduction case, proof-of-concept input, or crash trace (scrubbed of personal paths/tokens).
   - Impact assessment (e.g., guest-to-host crash vs. host code execution vs. PII leak in scrubbed output).

## Disclosure Policy

- We will acknowledge receipt of your report through the GitHub Security Advisory thread.
- Once a fix is verified and committed, we will publish the advisory and credit the reporter (unless you prefer to remain anonymous).
