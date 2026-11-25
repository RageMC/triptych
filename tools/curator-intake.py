#!/usr/bin/env python3
"""Map a public tracker issue to the private Curator workflow."""

import argparse
import json
import re
import subprocess

TRACKER = "RageMC/triptych-issues"
DISPATCH = "repos/RageMC/triptych/actions/workflows/curator-autofix.yml/dispatches"


def issue_number(value):
    match = re.fullmatch(rf"(?:https://github\.com/{TRACKER}/issues/|#)?([1-9][0-9]{{0,14}})", value)
    if match is None:
        raise argparse.ArgumentTypeError(f"expected an issue number or https://github.com/{TRACKER}/issues/NUMBER")
    return match[1]


def request(number):
    return {"ref": "main", "inputs": {"tracker_issue": number}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("issue", type=issue_number)
    parser.add_argument("--dispatch", action="store_true", help="send the request using the existing gh credentials")
    args = parser.parse_args()
    payload = json.dumps(request(args.issue))
    if args.dispatch:
        subprocess.run(["gh", "api", "--method", "POST", DISPATCH, "--input", "-"],
                       input=payload, text=True, check=True)
    else:
        print(payload)


if __name__ == "__main__":
    main()
