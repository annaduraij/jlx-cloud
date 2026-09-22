#!/usr/bin/env python3
# Author: Jay Annadurai
# Project: jlx-cloud
# Date: 22 September 2026
# File: scripts/render-cloud-init.py
# Description: Renders a released cloud-init template for Console or OCI CLI use.

"""Render a released jlx-cloud template for Console or OCI CLI use."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


REPO_DIR = Path(__file__).resolve().parent.parent
TEMPLATES = {
    "ubuntu": REPO_DIR / "cloud-init" / "ubuntu-26.04.yaml",
    "oci": REPO_DIR / "cloud-init" / "oci-ubuntu-26.04.yaml",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--provider", choices=sorted(TEMPLATES), required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--swap-gib", type=int, choices=range(17), required=True)
    parser.add_argument("--host", action="store_true")
    return parser.parse_args()


def replace_once(content: str, old: str, new: str) -> str:
    """Replace one template token and fail if the template contract drifts."""
    if content.count(old) != 1:
        raise SystemExit(f"template contract changed: expected one occurrence of {old!r}")
    return content.replace(old, new, 1)


def main() -> None:
    args = parse_args()
    content = TEMPLATES[args.provider].read_text(encoding="utf-8")

    user_args = f"--user, {json.dumps(args.user)}"
    if args.host:
        user_args += ", --host"
    content = replace_once(content, "--user, ubuntu", user_args)

    if args.provider == "oci":
        content = replace_once(
            content,
            "--swap-gib, '2'",
            f"--swap-gib, {json.dumps(str(args.swap_gib))}",
        )

    print(content, end="")


if __name__ == "__main__":
    main()
