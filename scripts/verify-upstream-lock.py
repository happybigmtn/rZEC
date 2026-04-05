#!/usr/bin/env python3
"""Verify the pinned upstream runtime contract before cutting a release."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LOCK_FILE = REPO_ROOT / "references" / "UPSTREAM.json"
DEFAULT_REPORT_DIR = REPO_ROOT / "reports"


def _fetch_json(url: str) -> dict:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "rZEC-release-verifier",
        },
    )
    with urllib.request.urlopen(request) as response:  # noqa: S310
        payload = json.loads(response.read().decode("utf-8"))
    if not isinstance(payload, dict):
        raise RuntimeError(f"Expected JSON object from {url}")
    return payload


def _release_url(repo: str, tag: str) -> str:
    owner, name = repo.rsplit("/", 2)[-2:]
    return f"https://api.github.com/repos/{owner}/{name}/releases/tags/{tag}"


def _docker_tag_url(repository: str, tag: str) -> str:
    return f"https://hub.docker.com/v2/repositories/{repository}/tags/{tag}"


def _git_remote_head(repo: str, branch: str) -> str:
    output = subprocess.check_output(  # noqa: S603
        ["git", "ls-remote", repo, branch],
        text=True,
    ).strip()
    if not output:
        raise RuntimeError(f"Branch {branch!r} not found for {repo}")
    return output.split()[0]


def _verify_release(repo_url: str, tag: str) -> dict:
    payload = _fetch_json(_release_url(repo_url, tag))
    return {
        "repo": repo_url,
        "tag": tag,
        "html_url": payload.get("html_url"),
        "published_at": payload.get("published_at"),
    }


def _verify_docker_image(repository: str, tag: str, expected_digest: str) -> dict:
    payload = _fetch_json(_docker_tag_url(repository, tag))
    observed_digest = payload.get("digest")
    if observed_digest != expected_digest:
        raise RuntimeError(
            f"Docker image {repository}:{tag} digest mismatch: "
            f"expected {expected_digest}, got {observed_digest}"
        )
    return {
        "repository": repository,
        "tag": tag,
        "digest": observed_digest,
        "last_updated": payload.get("last_updated"),
    }


def _verify_branch(repo: str, branch: str, commit: str) -> dict:
    observed_commit = _git_remote_head(repo, branch)
    if observed_commit != commit:
        raise RuntimeError(
            f"Branch {repo} {branch} moved: expected {commit}, got {observed_commit}"
        )
    return {
        "repo": repo,
        "branch": branch,
        "commit": observed_commit,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--lock-file", default=str(DEFAULT_LOCK_FILE))
    parser.add_argument("--output")
    args = parser.parse_args()

    lock_path = Path(args.lock_file).expanduser().resolve()
    payload = json.loads(lock_path.read_text(encoding="utf-8"))
    output_path = (
        Path(args.output).expanduser().resolve()
        if args.output
        else DEFAULT_REPORT_DIR / f"verification-{args.release_tag}.json"
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)

    report = {
        "release_tag": args.release_tag,
        "status": "PASS",
        "timestamp": datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "lock_file": str(lock_path.relative_to(REPO_ROOT)),
        "checks": {
            "zebra_release": _verify_release(
                payload["zebra"]["source_repo"],
                payload["zebra"]["source_release_tag"],
            ),
            "zebra_image": _verify_docker_image(
                payload["zebra"]["docker_repository"],
                payload["zebra"]["docker_tag"],
                payload["zebra"]["docker_digest"],
            ),
            "lightwalletd_release": _verify_release(
                payload["lightwalletd"]["source_repo"],
                payload["lightwalletd"]["source_release_tag"],
            ),
            "lightwalletd_image": _verify_docker_image(
                payload["lightwalletd"]["docker_repository"],
                payload["lightwalletd"]["docker_tag"],
                payload["lightwalletd"]["docker_digest"],
            ),
            "snomp_branch": _verify_branch(
                payload["miner_stack"]["snomp"]["repo"],
                payload["miner_stack"]["snomp"]["branch"],
                payload["miner_stack"]["snomp"]["commit"],
            ),
            "nheqminer_branch": _verify_branch(
                payload["miner_stack"]["nheqminer"]["repo"],
                payload["miner_stack"]["nheqminer"]["branch"],
                payload["miner_stack"]["nheqminer"]["commit"],
            ),
        },
    }

    output_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
