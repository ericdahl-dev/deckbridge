#!/usr/bin/env python3
"""Checks the domain docs (CLAUDE.md: one GLOSSARY.md and docs/adr/ at the repo root):
- GLOSSARY.md exists and defines terms ("**Term**:" lines), and every term is used somewhere outside it (code, docs,
  site, scripts), so a term the project stopped using fails instead of going stale
- each ADR is docs/adr/NNNN-slug.md, numbered from 0001 with no gaps, and has a "# " title, a date (YYYY-MM-DD) and at
  least one issue link (#N)
Standard library only. Run: python3 -I scripts/check_domain_docs.py [repo]   (exits 1 on any problem)
Tested by scripts/test_check_domain_docs.py."""
import os, re, sys

GLOSSARY = "GLOSSARY.md"
ADR_DIR = os.path.join("docs", "adr")
TERM = re.compile(r"^\*\*(.+?)\*\*:\s*$", re.MULTILINE)
ADR_NAME = re.compile(r"^(\d{4})-[a-z0-9-]+\.md$")
DATE = re.compile(r"\b\d{4}-\d{2}-\d{2}\b")
ISSUE = re.compile(r"#\d+\b")
# Where a term's use counts: the repo's own text, not its build output, tools' caches or the glossary itself.
SKIP_DIRS = {".git", "build", ".build", "node_modules", ".taste-skill", "DerivedData", ".swiftpm"}
TEXT = (".swift", ".md", ".py", ".mjs", ".js", ".html", ".json", ".yml", ".yaml", ".txt", ".sh", ".css")


def corpus(root):
    """The repo's text, lower-cased, without the glossary."""
    parts = []
    for directory, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in names:
            path = os.path.join(directory, name)
            if os.path.relpath(path, root) == GLOSSARY or not name.endswith(TEXT):
                continue
            try:
                with open(path, encoding="utf-8") as f:
                    parts.append(f.read().lower())
            except (UnicodeDecodeError, OSError):
                continue
    return "\n".join(parts)


def check_glossary(root):
    path = os.path.join(root, GLOSSARY)
    if not os.path.isfile(path):
        return [f"{GLOSSARY}: missing"]
    with open(path, encoding="utf-8") as f:
        terms = TERM.findall(f.read())
    if not terms:
        return [f"{GLOSSARY}: defines no terms (**Term**: lines)"]
    text = corpus(root)
    return [f'{GLOSSARY}: "{term}" isn\'t used anywhere in the code or docs' for term in terms if term.lower() not in text]


def check_adrs(root):
    directory = os.path.join(root, ADR_DIR)
    if not os.path.isdir(directory):
        return []
    out, numbers = [], []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".md"):
            continue
        shown = f"docs/adr/{name}"
        match = ADR_NAME.match(name)
        if not match:
            out.append(f"{shown}: isn't named NNNN-slug.md")
            continue
        numbers.append(int(match.group(1)))
        with open(os.path.join(directory, name), encoding="utf-8") as f:
            text = f.read()
        if not text.startswith("# "):
            out.append(f"{shown}: doesn't start with a # title")
        if not DATE.search(text):
            out.append(f"{shown}: has no date (YYYY-MM-DD)")
        if not ISSUE.search(text):
            out.append(f"{shown}: links no issue (#N)")
    for missing in sorted(set(range(1, max(numbers, default=0) + 1)) - set(numbers)):
        out.append(f"docs/adr: numbers skip {missing:04d}")
    return out


def problems(root):
    return check_glossary(root) + check_adrs(root)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    found = problems(root)
    for problem in found:
        print("FAIL:", problem)
    print("== Domain docs check passed" if not found else f"== {len(found)} domain docs problem(s)")
    sys.exit(1 if found else 0)


if __name__ == "__main__":
    main()
