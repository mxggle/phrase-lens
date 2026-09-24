#!/usr/bin/env python3
"""Plan and prepare a PhraseLens release from commits since the last tag."""

import argparse
import datetime
import json
import plistlib
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLIST = ROOT / "packaging/Info.plist"
CHANGELOG = ROOT / "CHANGELOG.md"
LANDING = [ROOT / "landing/index.html", ROOT / "landing/zh/index.html"]
REPO = "https://github.com/mxggle/phrase-lens"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def plan():
    current = plistlib.loads(PLIST.read_bytes())
    version = current["CFBundleShortVersionString"]
    tag = f"v{version}"
    if subprocess.run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag}"], cwd=ROOT,
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise SystemExit(f"Missing {tag}; fetch tags before planning a release")
    if subprocess.run(["git", "merge-base", "--is-ancestor", tag, "HEAD"], cwd=ROOT).returncode:
        raise SystemExit(f"{tag} is not an ancestor of HEAD; release from updated main")
    raw = git("log", "--no-merges", "--format=%s%x1f%b%x1e", f"{tag}..HEAD")
    commits = []
    for record in raw.split("\x1e"):
        if not record.strip():
            continue
        subject, _, body = record.strip().partition("\x1f")
        if re.match(r"chore\(release\)!?:", subject, re.I):
            continue
        commits.append((subject.strip(), body.strip()))
    if not commits:
        return {"release": False, "current": version, "reason": "No changes since last release"}
    bump = "patch"
    if any("BREAKING CHANGE:" in body or re.match(r"\w+(?:\([^)]*\))?!:", subject) for subject, body in commits):
        bump = "major"
    elif any(re.match(r"feat(?:\([^)]*\))?:", subject) for subject, _ in commits):
        bump = "minor"
    major, minor, patch = map(int, version.split("."))
    next_version = {"major": f"{major + 1}.0.0", "minor": f"{major}.{minor + 1}.0",
                    "patch": f"{major}.{minor}.{patch + 1}"}[bump]
    return {"release": True, "current": version, "next": next_version,
            "build": str(int(current["CFBundleVersion"]) + 1), "bump": bump,
            "commits": [subject for subject, _ in reversed(commits)]}


def prepare(result):
    if not result["release"]:
        return
    old, new = result["current"], result["next"]
    plist = PLIST.read_text()
    for key, old_value, new_value in (("CFBundleShortVersionString", old, new),
                                      ("CFBundleVersion", str(int(result["build"]) - 1), result["build"])):
        pattern = rf"(<key>{key}</key>\s*<string>){re.escape(old_value)}(</string>)"
        plist, count = re.subn(pattern, lambda m: m.group(1) + new_value + m.group(2), plist)
        if count != 1:
            raise SystemExit(f"Expected one {key} value in Info.plist")
    changelog = CHANGELOG.read_text()
    marker = "## [Unreleased]\n"
    if changelog.count(marker) != 1:
        raise SystemExit("Expected one Unreleased section")
    categories = {"Added": [], "Changed": [], "Fixed": []}
    for subject in result["commits"]:
        kind = re.match(r"^(feat|fix|perf|refactor|docs|build|chore|test)(?:\([^)]*\))?!?:\s*(.+)$", subject)
        group = "Added" if kind and kind[1] == "feat" else "Fixed" if kind and kind[1] == "fix" else "Changed"
        categories[group].append("- " + (kind[2] if kind else subject).rstrip("." ) + ".")
    notes = "\n".join(f"### {name}\n\n" + "\n".join(items) + "\n" for name, items in categories.items() if items)
    date = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).date().isoformat()
    next_heading = re.search(r"^## \[", changelog[changelog.index(marker) + len(marker):], re.M)
    if not next_heading:
        raise SystemExit("Could not find previous release heading")
    section_start = changelog.index(marker) + len(marker)
    section_end = section_start + next_heading.start()
    unreleased_notes = changelog[section_start:section_end].strip()
    if unreleased_notes:
        notes = unreleased_notes + "\n\n" + notes
    changelog = changelog[:section_start] + f"\n## [{new}] — {date}\n\n{notes}\n" + changelog[section_end:]
    old_link = f"[Unreleased]: {REPO}/compare/v{old}...HEAD"
    if changelog.count(old_link) != 1:
        raise SystemExit("Unreleased comparison link does not match current version")
    changelog = changelog.replace(old_link, f"[Unreleased]: {REPO}/compare/v{new}...HEAD\n"
                                  f"[{new}]: {REPO}/compare/v{old}...v{new}", 1)
    updated_pages = {}
    for path in LANDING:
        page = path.read_text()
        updated, count = re.subn(r'(data-release-version="v)\d+\.\d+\.\d+(" href="https://github.com/mxggle/phrase-lens/releases/tag/v)\d+\.\d+\.\d+',
                                 lambda m: m.group(1) + new + m.group(2) + new, page)
        if count != 1:
            raise SystemExit(f"Expected one release version link in {path}")
        updated, label_count = re.subn(r'(data-release-label>)(?:v)?\d+\.\d+\.\d+(</span>)',
                                       lambda m: m.group(1) + new + m.group(2), updated)
        if label_count != 1:
            raise SystemExit(f"Expected one release label in {path}")
        updated_pages[path] = updated
    PLIST.write_text(plist)
    CHANGELOG.write_text(changelog)
    for path, updated in updated_pages.items():
        path.write_text(updated)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["plan", "prepare"])
    args = parser.parse_args()
    result = plan()
    if args.command == "prepare":
        prepare(result)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
