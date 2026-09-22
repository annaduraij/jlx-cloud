#!/usr/bin/env python3
# Author: Jay Annadurai
# Project: jlx-cloud
# Date: 22 September 2026
# File: scripts/build-dot-jay-bundle.py
# Description: Builds a deterministic, secret-scanned dot-jay cloud runtime bundle.

"""Create the minimal dot-jay runtime published with a jlx-cloud release."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile


EXACT_PATHS = {
    "main.py",
    "_profiles/lx-cli.json",
    "_profiles/jlx-cloud.json",
    "_profiles/jlx-cloud-host.json",
    "packages/packages.json",
    "packages/profiles.json",
    "shell/groups.json",
    "ssh/config",
    "git/git-config.json",
}
PATH_PREFIXES = (
    "scripts/",
    "shell/modules/base/",
    "shell/modules/cli/",
)
SECRET_PATTERNS = (
    re.compile(rb"github_pat_[A-Za-z0-9_]+"),
    re.compile(rb"gh[pousr]_[A-Za-z0-9_]+"),
    re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
)
CLOUD_PACKAGES = {"sudo", "zsh", "git", "curl", "tmux", "jq", "htop"}
CLOUD_INSTALL_PROFILES = {"minimal", "lx-cli", "jlx-cloud-host"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-repo", type=Path, required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--output-dir", type=Path, default=Path("dist"))
    return parser.parse_args()


def git(repo: Path, *args: str) -> bytes:
    """Run a read-only Git command against the private source checkout."""
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout


def selected_paths(repo: Path, commit: str) -> list[str]:
    """Select only files required by the two dot-jay cloud profiles."""
    tracked = git(repo, "ls-tree", "-r", "--name-only", commit).decode().splitlines()
    selected = sorted(
        path
        for path in tracked
        if path in EXACT_PATHS or path.startswith(PATH_PREFIXES)
    )
    missing = sorted(EXACT_PATHS - set(selected))
    if missing:
        raise SystemExit(f"dot-jay ref is missing required runtime files: {', '.join(missing)}")
    return selected


def sanitized_content(repo: Path, commit: str, path: str) -> bytes:
    """Read one committed file and reduce catalogs to the public cloud subset."""
    content = git(repo, "show", f"{commit}:{path}")
    if path == "git/git-config.json":
        config = json.loads(content)
        config.pop("user.name", None)
        config.pop("user.email", None)
        content = (json.dumps(config, indent=2) + "\n").encode()
    elif path == "packages/packages.json":
        catalog = json.loads(content)
        packages = catalog.get("packages", {})
        missing = sorted(CLOUD_PACKAGES - set(packages))
        if missing:
            raise SystemExit(f"dot-jay is missing cloud packages: {', '.join(missing)}")
        catalog["packages"] = {
            name: package for name, package in packages.items() if name in CLOUD_PACKAGES
        }
        content = (json.dumps(catalog, indent=2) + "\n").encode()
    elif path == "packages/profiles.json":
        catalog = json.loads(content)
        profiles = catalog.get("profiles", {})
        missing = sorted(CLOUD_INSTALL_PROFILES - set(profiles))
        if missing:
            raise SystemExit(f"dot-jay is missing cloud install profiles: {', '.join(missing)}")
        catalog["profiles"] = {
            name: profile
            for name, profile in profiles.items()
            if name in CLOUD_INSTALL_PROFILES
        }
        content = (json.dumps(catalog, indent=2) + "\n").encode()

    # Runtime comments and generated SSH-key labels do not need a personal address.
    content = content.replace(b"jay@jannadurai.com", b"jlx-cloud@localhost")

    for pattern in SECRET_PATTERNS:
        if pattern.search(content):
            raise SystemExit(f"refusing to bundle secret-shaped content from {path}")
    return content


def tar_info(path: str, size: int) -> tarfile.TarInfo:
    """Create stable archive metadata so equal inputs produce equal bytes."""
    info = tarfile.TarInfo(f"dot-jay/{path}")
    info.size = size
    info.mode = 0o644
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = 0
    return info


def validate_public_paths(paths: list[str]) -> None:
    """Reject path classes that must never enter the public release asset."""
    forbidden_names = {".env", "ReadMe.md", "README.md", "AGENTS.md"}
    for path in paths:
        parts = PurePosixPath(path).parts
        if forbidden_names.intersection(parts):
            raise SystemExit(f"refusing to publish private documentation or settings: {path}")
        if "identities" in parts or "private-keys" in parts:
            raise SystemExit(f"refusing to publish SSH identity material: {path}")


def build_bundle(repo: Path, commit: str, output_path: Path) -> str:
    """Write the runtime archive and return its SHA-256 digest."""
    paths = selected_paths(repo, commit)
    validate_public_paths(paths)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("wb") as raw_output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw_output, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as archive:
                for path in paths:
                    content = sanitized_content(repo, commit, path)
                    archive.addfile(tar_info(path, len(content)), io.BytesIO(content))

                marker = f"{commit}\n".encode()
                archive.addfile(
                    tar_info(".jlx-source-commit", len(marker)),
                    io.BytesIO(marker),
                )

    digest = hashlib.sha256(output_path.read_bytes()).hexdigest()
    output_path.with_suffix(output_path.suffix + ".sha256").write_text(
        f"{digest}  {output_path.name}\n",
        encoding="utf-8",
    )
    return digest


def main() -> None:
    args = parse_args()
    repo = args.source_repo.resolve()
    commit = git(repo, "rev-parse", f"{args.ref}^{{commit}}").decode().strip()
    short_commit = commit[:12]
    output_path = args.output_dir / f"dot-jay-runtime-{short_commit}.tar.gz"
    digest = build_bundle(repo, commit, output_path)
    print(f"bundle={output_path}")
    print(f"commit={commit}")
    print(f"sha256={digest}")


if __name__ == "__main__":
    main()
