#!/usr/bin/env python3
"""Says whether CI's Mac jobs (Kit tests, App build) and its Deck panel job need to run for a change.
Reads the changed paths, one per line, on stdin; prints mac=true|false and deck_panel=true|false for $GITHUB_OUTPUT.
`--base EVENT_NAME EVENT_PATH` prints instead the commit the change is measured against (#546).
Tested by scripts/test_ci_changes.py."""
import fnmatch, json, sys

# Changes only the Linux jobs check (Site check, spelling): the website, its scripts, Markdown docs and their check,
# and the LC6000 firmware tool.
# Anything else, including .github/ and the release scripts the Kit job tests, runs the Mac jobs too.
SITE_ONLY = ["website/*", "scripts/check_site.py", "scripts/test_check_site.py", "scripts/site-preview.sh",
             "scripts/test_*.mjs", "*.md",
             # the domain docs' check (GLOSSARY.md, docs/adr), which the Site check job runs
             "scripts/check_domain_docs.py", "scripts/test_check_domain_docs.py",
             # the LC6000 firmware patch tool (#430) and its tests, which the Site check job runs
             "tools/lc6000-firmware/*",
             # the drawn display firmware (#457) and its tests, which the Display firmware job runs
             "tools/lc6000-display-fw/*",
             # the deck panel's firmware (#615) and its tests, which the Deck panel job runs
             "tools/deck-panel/*"]
# Inside those, paths the Mac jobs also test: the shared message vectors (#456), walked by the Kit tests too, and the
# drawn display's reference images (#464), which the Kit tests check against the Swift renderer, and the display feed's
# example messages (#490), which the Kit tests walk too. The LC6000 patch descriptions, whose copies in the firmware
# updater's catalog (#686) the Kit tests check against them.
ALSO_MAC = ["tools/lc6000-display-fw/vectors/*", "tools/lc6000-display-fw/test/ref/*", "tools/deck-panel/feed/*",
            "tools/lc6000-firmware/patches/*",
            # make arm's build record reader and what it imports, which the updater's block staging step (#696) uses
            "tools/lc6000-firmware/build_record.py", "tools/lc6000-firmware/dfupatch.py",
            "tools/lc6000-firmware/drawn_flash.py", "tools/lc6000-firmware/build_upper_dfu.py",
            "tools/lc6000-display-fw/arm/upper_header.py"]
# What the Deck panel job (#615) builds and tests, and CI itself, so a change to the job runs it. The icon SVG the
# panel's logo is made from (#651), whose drift test the job runs (#669).
# The app's release keys, which the panel must trust too (#690).
DECK_PANEL = ["tools/deck-panel/*", ".github/workflows/ci.yml", "design/icon/icon-1-deck-ring.svg",
              "Packages/FirmwareUpdaterKit/Sources/FirmwareRelease/ReleaseKeys.swift"]


def site_only(path):
    if any(fnmatch.fnmatchcase(path, pattern) for pattern in ALSO_MAC):
        return False
    return not path.startswith(".github/") and any(fnmatch.fnmatchcase(path, pattern) for pattern in SITE_ONLY)


def needs_mac(paths):
    if not paths:
        return True  # an unknown change: run everything
    return not all(site_only(path) for path in paths)


def needs_deck_panel(paths):
    if not paths:
        return True  # an unknown change: run everything
    return any(fnmatch.fnmatchcase(path, pattern) for path in paths for pattern in DECK_PANEL)


def diff_base(event_name, event):
    """The commit a run's change is measured against: a pull request's base, a merge queue entry's base (#546), a
    push's previous commit. Empty when unknown, which runs everything."""
    if event_name == "pull_request":
        return ((event.get("pull_request") or {}).get("base") or {}).get("sha") or ""
    if event_name == "merge_group":
        return (event.get("merge_group") or {}).get("base_sha") or ""
    if event_name == "push":
        return event.get("before") or ""
    return ""


def main():
    if sys.argv[1:2] == ["--base"]:
        name, path = sys.argv[2], sys.argv[3]
        try:
            with open(path) as f:
                event = json.load(f)
        except (OSError, ValueError):
            event = {}
        print(diff_base(name, event))
        return
    paths = [line.strip() for line in sys.stdin if line.strip()]
    print(f"mac={'true' if needs_mac(paths) else 'false'}")
    print(f"deck_panel={'true' if needs_deck_panel(paths) else 'false'}")


if __name__ == "__main__":
    main()
