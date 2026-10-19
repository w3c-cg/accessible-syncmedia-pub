#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./backup-repo.sh [OWNER/REPO] [OUTPUT_DIRECTORY]

Back up repository and wiki Git history, plus all open and closed issues,
comments, issue events, labels, and milestones, into a dated .tar.gz archive.

Defaults: GITHUB_REPOSITORY (or w3c-cg/accessible-syncmedia-pub), ./backups/repository
Requires: bash, git, gh (authenticated with read access), python3, and tar.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if (( $# > 2 )); then
  usage >&2
  exit 1
fi

repository="${1:-${GITHUB_REPOSITORY:-w3c-cg/accessible-syncmedia-pub}}"
output_directory="${2:-backups/repository}"
if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  printf 'Invalid repository: %s (expected OWNER/REPO)\n' "$repository" >&2
  exit 1
fi
for dependency in git gh python3 tar; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'Missing dependency: %s\n' "$dependency" >&2
    exit 1
  fi
done

started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
stamp="$(date -u '+%Y-%m-%dT%H-%M-%SZ')"
backup_name="${repository//\//-}-$stamp"
mkdir -p -- "$output_directory"
output_directory="$(cd -- "$output_directory" && pwd)"
archive="$output_directory/$backup_name.tar.gz"
if [[ -e "$archive" ]]; then
  printf 'Backup already exists: %s\n' "$archive" >&2
  exit 1
fi

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/backup-repo.XXXXXX")"
trap 'rm -rf -- "$work_directory"' EXIT
snapshot="$work_directory/$backup_name"
mkdir -p "$snapshot/issues" "$snapshot/wiki"
export GIT_TERMINAL_PROMPT=0

# Credentials are supplied at runtime, never embedded in remotes or archives.
clone_bundle() {
  local url="$1" name="$2"
  git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
    clone --mirror "$url" "$work_directory/$name.git"
  git -C "$work_directory/$name.git" fsck --full
  git -C "$work_directory/$name.git" bundle create "$snapshot/$name.bundle" --all
  git -C "$work_directory/$name.git" bundle verify "$snapshot/$name.bundle"
}

printf 'Backing up repository and wiki history for %s\n' "$repository"
clone_bundle "https://github.com/$repository.git" repository
# A failed or inaccessible wiki stops the backup instead of producing a partial one.
clone_bundle "https://github.com/$repository.wiki.git" wiki
git -C "$work_directory/wiki.git" archive HEAD | tar -xf - -C "$snapshot/wiki"

fetch_pages() {
  local name="$1" endpoint="$2"
  shift 2
  gh api --hostname github.com --method GET "repos/$repository/$endpoint" \
    --header 'Accept: application/vnd.github+json' \
    --field per_page=100 --paginate --slurp "$@" > "$work_directory/$name.json"
}

printf 'Exporting all issue tracker pages\n'
fetch_pages issues issues --field state=all --field sort=created --field direction=asc
fetch_pages comments issues/comments --field sort=created --field direction=asc
fetch_pages events issues/events
fetch_pages labels labels
fetch_pages milestones milestones --field state=all

python3 - "$work_directory" "$snapshot" "$repository" "$started_at" <<'PY'
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys

work, snapshot = map(Path, sys.argv[1:3])
repository, started_at = sys.argv[3:5]


def read_pages(name):
    pages = json.loads((work / f"{name}.json").read_text(encoding="utf-8"))
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise SystemExit(f"Invalid paginated response for {name}")
    return [record for page in pages for record in page]


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


issues = sorted(
    (issue for issue in read_pages("issues") if "pull_request" not in issue),
    key=lambda issue: issue["number"],
)
numbers = {issue["number"] for issue in issues}
if len(numbers) != len(issues):
    raise SystemExit("Duplicate issue numbers in export")
by_url = {issue["url"]: [] for issue in issues}
comments = [comment for comment in read_pages("comments") if comment["issue_url"] in by_url]
for comment in comments:
    by_url[comment["issue_url"]].append(comment)
for issue in issues:
    if issue["comments"] != len(by_url[issue["url"]]):
        raise SystemExit(
            f"Comment count mismatch for issue #{issue['number']}; "
            "the tracker may have changed during export. Rerun the backup."
        )
events = [event for event in read_pages("events") if event.get("issue", {}).get("url") in by_url]
labels, milestones = read_pages("labels"), read_pages("milestones")
for name, records in {
    "issues": issues, "comments": comments, "events": events,
    "labels": labels, "milestones": milestones,
}.items():
    write_json(snapshot / "issues" / f"{name}.json", records)

markdown = [f"# Issues: {repository}", "", f"Export started: {started_at}", ""]
for issue in issues:
    author = (issue.get("user") or {}).get("login", "deleted user")
    labels_text = ", ".join(label["name"] for label in issue["labels"]) or "None"
    assignees = ", ".join(user["login"] for user in issue["assignees"]) or "None"
    milestone = (issue.get("milestone") or {}).get("title", "None")
    markdown.extend([
        f"## #{issue['number']}: {issue['title']}", "",
        f"URL: {issue['html_url']}", "",
        f"State: {issue['state']} | Author: {author}", "",
        f"Created: {issue['created_at']} | Updated: {issue['updated_at']} | "
        f"Closed: {issue.get('closed_at') or 'N/A'}", "",
        f"Labels: {labels_text} | Assignees: {assignees} | Milestone: {milestone}", "",
        issue.get("body") or "(No description)", "",
    ])
    for comment in sorted(by_url[issue["url"]], key=lambda item: (item["created_at"], item["id"])):
        author = (comment.get("user") or {}).get("login", "deleted user")
        markdown.extend([
            f"### Comment by {author} at {comment['created_at']}", "",
            f"URL: {comment['html_url']}", "",
            comment.get("body") or "(No comment text)", "",
        ])
    markdown.extend(["---", ""])
(snapshot / "issues" / "issues.md").write_text("\n".join(markdown), encoding="utf-8")

# Hash every payload file, including the Git bundles and current wiki pages.
checksums, symlinks = {}, {}
for path in sorted(snapshot.rglob("*")):
    relative = path.relative_to(snapshot).as_posix()
    if path.is_symlink():
        symlinks[relative] = os.readlink(path)
    elif path.is_file():
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        checksums[relative] = digest.hexdigest()
counts = {
    "issues": len(issues),
    "open": sum(issue["state"] == "open" for issue in issues),
    "closed": sum(issue["state"] == "closed" for issue in issues),
    "comments": len(comments), "events": len(events),
    "labels": len(labels), "milestones": len(milestones),
}
write_json(snapshot / "manifest.json", {
    "schema_version": 1,
    "repository": repository,
    "export_started_at": started_at,
    "export_finished_at": datetime.now(timezone.utc).isoformat(),
    "counts": counts,
    "validation": {"comment_counts_match": True, "git_bundles_verified": True},
    "sha256": checksums,
    "symlinks": symlinks,
})
print(json.dumps(counts, indent=2))
PY

# Publish the archive only after all exports and integrity checks succeed.
tar -czf "$work_directory/$backup_name.tar.gz" -C "$work_directory" "$backup_name"
tar -tzf "$work_directory/$backup_name.tar.gz" >/dev/null
mv "$work_directory/$backup_name.tar.gz" "$archive"
printf 'Backup saved: %s\n' "$archive"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'archive=%s\n' "$archive" >> "$GITHUB_OUTPUT"
fi
