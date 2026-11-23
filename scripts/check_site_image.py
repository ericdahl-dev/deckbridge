#!/usr/bin/env python3
"""The website's server check (#767): website/Dockerfile and nginx.conf serve the site as the live one does.

With no argument it builds website/Dockerfile, runs it on a free local port and checks it over HTTP, then removes the
container. With --url it checks a running site instead, such as https://getdeckbridge.app, before and after a switch.

Checked, as the live site answered on 2026-11-22:
  - every file under website/ answers 200 with the repo's bytes and its content type (404.html excepted: it answers 404);
  - the clean URLs answer 200 with their index.html, with and without the trailing slash, never a redirect;
  - an unknown path answers 404 with the 404 page.
And new with #767 (the live site sent no cache headers):
  - HTML is never cached long: no-cache, or at most 5 minutes;
  - fonts and images are cached at least 30 days.

Usage: python3 -I scripts/check_site_image.py [--url BASE]
Needs Docker without --url (CI's Linux runner has it).
"""
import argparse
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "website"
IMAGE = "deckbridge-site-check"

# The content type each extension answered with on the live site (nginx's defaults; .md has none, so octet-stream).
TYPES = {
    ".html": "text/html", ".css": "text/css", ".js": "application/javascript", ".json": "application/json",
    ".txt": "text/plain", ".md": "application/octet-stream", ".xml": "text/xml", ".woff2": "font/woff2",
    ".png": "image/png", ".webp": "image/webp",
}

# Clean URLs the site links to, and the file each serves.
CLEAN = {
    "/": "index.html",
    "/for/lc6000/": "for/lc6000/index.html",
    "/for/lc6000": "for/lc6000/index.html",
    "/support/": "support/index.html",
    "/privacy/": "privacy/index.html",
    "/capture/": "capture/index.html",
}

NOT_FOUND_TEXT = "Track not found."


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def fetch(base, path, headers=None):
    """(status, headers, body) for base+path, without following redirects."""
    request = urllib.request.Request(base + path, headers=headers or {})
    try:
        with OPENER.open(request, timeout=10) as response:
            return response.status, response.headers, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.headers, error.read()


def site_files():
    return sorted(p.relative_to(SITE).as_posix() for p in SITE.rglob("*")
                  if p.is_file() and p.name not in {"Dockerfile", "nginx.conf", ".DS_Store"})


def content_type(headers):
    return (headers.get("Content-Type") or "").split(";")[0].strip()


def check_files(base):
    failures = []
    for name in site_files():
        status, headers, body = fetch(base, "/" + name)
        want_status = 404 if name == "404.html" else 200
        if status != want_status:
            failures.append(f"/{name}: status {status}, want {want_status}")
            continue
        if body != (SITE / name).read_bytes():
            failures.append(f"/{name}: bytes differ from website/{name}")
        want_type = TYPES.get(pathlib.PurePath(name).suffix)
        if want_type and content_type(headers) != want_type:
            failures.append(f"/{name}: content type {content_type(headers)!r}, want {want_type!r}")
    for path, name in CLEAN.items():
        status, headers, body = fetch(base, path)
        if status != 200:
            failures.append(f"{path}: status {status}, want 200")
        elif body != (SITE / name).read_bytes():
            failures.append(f"{path}: bytes differ from website/{name}")
    return failures


def check_not_found(base):
    status, headers, body = fetch(base, "/no-such-track/")
    failures = []
    if status != 404:
        failures.append(f"/no-such-track/: status {status}, want 404")
    if NOT_FOUND_TEXT not in body.decode("utf-8", "replace"):
        failures.append(f"/no-such-track/: no {NOT_FOUND_TEXT!r}")
    return failures


def max_age(headers):
    """The Cache-Control max-age in seconds, 0 for no-cache or no-store, None when there's no Cache-Control."""
    value = headers.get("Cache-Control")
    if value is None:
        return None
    parts = [part.strip() for part in value.split(",")]
    if "no-cache" in parts or "no-store" in parts:
        return 0
    ages = [int(part.split("=", 1)[1]) for part in parts if part.startswith("max-age=")]
    return ages[0] if ages else None


SHORT = 300
LONG = 30 * 24 * 3600


def check_cache(base):
    failures = []
    for path in ["/", "/for/lc6000/", "/support/", "/index.html", "/no-such-track/"]:
        age = max_age(fetch(base, path)[1])
        if age is None or age > SHORT:
            failures.append(f"{path}: HTML cached for {age} s, want no-cache or at most {SHORT} s")
    long_lived = ["/fonts/Geist.woff2", "/fonts/GeistMono.woff2"] + sorted(
        "/" + p.relative_to(SITE).as_posix() for p in (SITE / "img").iterdir() if p.suffix in {".png", ".webp"})
    for path in long_lived:
        age = max_age(fetch(base, path)[1])
        if age is None or age < LONG:
            failures.append(f"{path}: cached for {age} s, want at least {LONG} s")
    return failures


CHECKS = [check_files, check_not_found, check_cache]


def run_checks(base):
    failures = [failure for check in CHECKS for failure in check(base)]
    for failure in failures:
        print("FAIL", failure)
    print(f"{len(failures)} failures against {base}")
    return 1 if failures else 0


def wait_up(base):
    for _ in range(50):
        try:
            fetch(base, "/")
            return
        except OSError:
            time.sleep(0.2)
    raise SystemExit(f"The site at {base} didn't answer.")


def with_image():
    subprocess.run(["docker", "build", "-q", "-t", IMAGE, str(SITE)], check=True)
    container = subprocess.run(["docker", "run", "-d", "--rm", "-p", "127.0.0.1::80", IMAGE],
                               check=True, capture_output=True, text=True).stdout.strip()
    try:
        port = subprocess.run(["docker", "port", container, "80/tcp"], check=True, capture_output=True,
                              text=True).stdout.split("\n")[0].rsplit(":", 1)[1]
        base = f"http://127.0.0.1:{port}"
        wait_up(base)
        return run_checks(base)
    finally:
        subprocess.run(["docker", "stop", container], capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--url", help="check this running site instead of building the image")
    args = parser.parse_args()
    return run_checks(args.url.rstrip("/")) if args.url else with_image()


if __name__ == "__main__":
    sys.exit(main())
