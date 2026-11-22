#!/usr/bin/env python3
"""Distributes an uploaded TestFlight build, for the release workflow (#180).

Waits for the build to finish processing, sets its What to Test from docs/TESTFLIGHT.md and adds it to the Internal
group. Only with EXTERNAL=1 (#244) does it also add it to the external group and submit it for Beta App Review. Every step is safe to run again. Uses the App Store Connect API with the
key the upload uses (Python standard library plus `openssl`, as ci_profile.py does). Never prints the key or a token.
Tested by scripts/test_testflight_distribute.py, through an injected HTTP layer: http(method, path, body, query)
returns (status, json).
"""
import json, os, sys, time, urllib.error, urllib.parse, urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
PLATFORM = "MAC_OS"
INTERNAL_GROUP = "Internal"
EXTERNAL_GROUP = "Syndicate"
# App Store Connect usually processes a Mac build in 5 to 30 minutes.
POLL_SECONDS = 30
PROCESSING_TIMEOUT = 60 * 60


class DistributeError(Exception):
    """A step that can't go on, with what to do about it."""


class TestInformationMissing(DistributeError):
    """External testing needs the app's Test Information, a one-time step for the account holder in App Store
    Connect: it holds their contact details, so this script never fills it in."""

    def __init__(self, missing):
        super().__init__(
            f"External testing needs Test Information in App Store Connect ({missing}). Fill it in once under "
            "TestFlight > Test Information (Beta App Description, Feedback Email, and Beta App Review contact "
            "details), then re-run this workflow with workflow_dispatch for this version and build.")


def send(http, method, path, body):
    status, response = http(method, path, body, None)
    if status >= 400:
        raise DistributeError(f"App Store Connect said {status} for {method} {path}: {detail(response)}")
    return response


def get(http, path, query=None):
    status, body = http("GET", path, None, query)
    if status >= 400:
        raise DistributeError(f"App Store Connect said {status} for GET {path}: {detail(body)}")
    return body


def detail(body):
    """The API's error details, never anything from the request."""
    errors = (body or {}).get("errors") or []
    return "; ".join(f"{e.get('code', '')} {e.get('detail', '')}".strip() for e in errors) or "no detail"


def find_app(http, bundle_id):
    apps = get(http, "/apps", {"filter[bundleId]": bundle_id})["data"]
    app = next((a for a in apps if a["attributes"]["bundleId"] == bundle_id), None)
    if app is None:
        raise DistributeError(f"No app with bundle ID {bundle_id} in App Store Connect.")
    return app["id"]


def find_build(http, bundle_id, version, build_number, sleep, timeout=PROCESSING_TIMEOUT):
    """The build's id once it has processed, by marketing version and build number (matched exactly: "42.1" is run
    42, attempt 1). A build not listed yet counts as still processing: it appears a little after the upload."""
    app = find_app(http, bundle_id)
    query = {"filter[app]": app, "filter[preReleaseVersion.version]": version,
             "filter[version]": build_number, "filter[preReleaseVersion.platform]": PLATFORM}
    waited, state = 0, "not listed yet"
    while True:
        builds = get(http, "/builds", query)["data"]
        build = next((b for b in builds if b["attributes"]["version"] == build_number), None)
        state = build["attributes"]["processingState"] if build else "not listed yet"
        if state == "VALID":
            print(f"Build {version} ({build_number}) has processed.")
            return build["id"]
        if state in ("FAILED", "INVALID"):
            raise DistributeError(f"Build {version} ({build_number}) is {state} in App Store Connect; it can't be distributed.")
        if waited >= timeout:
            raise DistributeError(f"Build {version} ({build_number}) is still {state} after {waited // 60} minutes.")
        print(f"Build {version} ({build_number}): {state}, waiting {POLL_SECONDS} s.")
        sleep(POLL_SECONDS)
        waited += POLL_SECONDS


def what_to_test(doc):
    """The What to Test text: everything after the doc's first "---" rule. TestFlight keeps line breaks, so a line
    wrapped in the doc joins the one before it; blank lines and new bullets ("- ") start a new line."""
    _, _, text = doc.partition("\n---\n")
    lines = []
    for raw in text.strip().splitlines():
        line = raw.strip()
        if lines and line and lines[-1] and not line.startswith("- "):
            lines[-1] += " " + line
        else:
            lines.append(line)
    return "\n".join(lines)


def set_what_to_test(http, build, text, locale="en-US", keep=False):
    """Sets the build's What to Test, creating its localization or updating it, so a rerun writes the same text. With
    `keep` (#312: an older build sent again by hand), a build that already has a text keeps it."""
    existing = get(http, f"/builds/{build}/betaBuildLocalizations")["data"]
    localization = next((l for l in existing if l["attributes"]["locale"] == locale), None)
    if keep and localization and localization["attributes"].get("whatsNew"):
        print(f"What to Test kept ({locale}): the build already has its own.")
        return
    if localization:
        send(http, "PATCH", f"/betaBuildLocalizations/{localization['id']}", {"data": {
            "type": "betaBuildLocalizations", "id": localization["id"], "attributes": {"whatsNew": text}}})
    else:
        send(http, "POST", "/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations", "attributes": {"locale": locale, "whatsNew": text},
            "relationships": {"build": {"data": {"type": "builds", "id": build}}}}})
    print(f"What to Test set ({locale}, {len(text)} characters).")


def add_to_group(http, app, build, name):
    """Adds the build to the beta group with exactly this name, once: a build already in it, or an internal group
    that gets every build by itself, is left alone. Any refusal fails with the API's words."""
    groups = get(http, "/betaGroups", {"filter[app]": app, "filter[name]": name})["data"]
    group = next((g for g in groups if g["attributes"]["name"] == name), None)
    if group is None:
        raise DistributeError(f'No beta group named "{name}" for this app in App Store Connect.')
    attributes = group["attributes"]
    if attributes.get("isInternalGroup") and attributes.get("hasAccessToAllBuilds"):
        print(f'"{name}" gets every build automatically.')
        return
    members = get(http, f"/betaGroups/{group['id']}/relationships/builds", {"limit": 200})["data"]
    if any(m["id"] == build for m in members):
        print(f'Already in "{name}".')
        return
    status, response = http("POST", f"/betaGroups/{group['id']}/relationships/builds",
                            {"data": [{"type": "builds", "id": build}]}, None)
    if status >= 400:
        raise DistributeError(f'Couldn\'t add the build to "{name}": {status} {detail(response)}')
    print(f'Added to "{name}".')


REVIEW_CONTACT = {"contactFirstName": "first name", "contactLastName": "last name", "contactPhone": "phone",
                  "contactEmail": "email"}


def check_test_information(http, app, locale="en-US"):
    """External review needs the beta description and feedback email, and the review contact. Checked first, so
    a missing one says what to fill in instead of failing on the submission."""
    contact = get(http, f"/apps/{app}/betaAppReviewDetail")["data"]["attributes"]
    missing = [label for key, label in REVIEW_CONTACT.items() if not contact.get(key)]
    if missing:
        raise TestInformationMissing("Beta App Review contact " + ", ".join(missing))
    localizations = [l["attributes"] for l in get(http, f"/apps/{app}/betaAppLocalizations")["data"]]
    localization = next((l for l in localizations if l.get("locale") == locale), {})
    if not localization.get("description"):
        raise TestInformationMissing(f"Beta App Description, {locale}")
    if not localization.get("feedbackEmail"):
        raise TestInformationMissing(f"Feedback Email, {locale}")


def submit_for_review(http, app, build):
    """Submits the build for Beta App Review, once. Already submitted, by an earlier run or by hand, is done."""
    check_test_information(http, app)
    # The submissions list, filtered by build: empty when there's none (the build's own relationship may 404 instead).
    existing = next(iter(get(http, "/betaAppReviewSubmissions", {"filter[build]": build})["data"]), None)
    if existing:
        print(f"Already submitted for Beta App Review ({existing['attributes'].get('betaReviewState', 'submitted')}).")
        return
    status, response = http("POST", "/betaAppReviewSubmissions", {"data": {
        "type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": build}}}}}, None)
    if status < 400:
        print("Submitted for Beta App Review.")
        return
    text = detail(response)
    # Missing Test Information, by the API's words for it (#312: "contact" alone matched unrelated errors).
    lowered = text.lower()
    if any(words in lowered for words in ("review information", "test information", "contact email", "contact phone",
                                          "contact first name", "contact last name", "contact information")):
        raise TestInformationMissing(text)
    if status == 409 and "already" in text.lower():
        print("Already submitted for Beta App Review.")
        return
    raise DistributeError(f"Couldn't submit for Beta App Review: {status} {text}")


def dry_run(http):
    """Reads everything, changes nothing: each change is printed instead of sent."""
    def wrapped(method, path, body=None, query=None):
        if method == "GET":
            return http(method, path, body, query)
        print(f"dry run: would {method} {path}")
        return (201 if method == "POST" else 200), {"data": {"id": "dry-run"}}
    return wrapped


def keep_from(value):
    """KEEP_WHAT_TO_TEST from the environment (#312): on only for "1" or "true"."""
    return value in ("1", "true")


def external_from(value):
    """EXTERNAL from the environment: on only for "1" or "true" (#244). Anything else, or unset, is internal only."""
    return value in ("1", "true")


def run(http, bundle_id, version, build_number, doc_path, sleep, external=False, keep_what_to_test=False):
    """The whole distribution. Internal only unless `external` (#244): then the build also goes to the external group
    and Beta App Review. Internal testers get the build even when the external half can't go on (missing Test
    Information): that half is reported as failed and the run exits non-zero. Returns the exit code."""
    try:
        app = find_app(http, bundle_id)
        build = find_build(http, bundle_id, version, build_number, sleep)
        with open(doc_path, encoding="utf-8") as doc:
            set_what_to_test(http, build, what_to_test(doc.read()), keep=keep_what_to_test)
        add_to_group(http, app, build, INTERNAL_GROUP)
    except DistributeError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    if not external:
        print(f"Internal only: not added to {EXTERNAL_GROUP} and not submitted for Beta App Review. "
              "Tag with [external] in the message, or run the workflow with external, to send it out.")
        return 0
    try:
        check_test_information(http, app)
        add_to_group(http, app, build, EXTERNAL_GROUP)
        submit_for_review(http, app, build)
    except DistributeError as error:
        print("Internal testers have the build. The external step failed.", file=sys.stderr)
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


def api_http(method, path, body=None, query=None):
    """The real HTTP layer: one signed request. Errors come back as (status, json); the token is never printed."""
    import ci_profile  # the ES256 token, made with openssl from ASC_KEY_PATH
    url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
    request = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None)
    request.add_header("Authorization", "Bearer " + ci_profile.token())
    if body:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw)
        except ValueError:
            return error.code, {"errors": [{"detail": raw.decode(errors="replace")[:300]}]}


def main():
    """Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, VERSION, BUILD_NUMBER, WHAT_TO_TEST
    (default docs/TESTFLIGHT.md), EXTERNAL=1 to also send it to the external group and Beta App Review (#244; internal
    only otherwise), KEEP_WHAT_TO_TEST=1 to leave a build's existing What to Test alone (#312), and DRY_RUN=1 to read
    everything and change nothing."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    doc = os.environ.get("WHAT_TO_TEST", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "TESTFLIGHT.md"))
    http = dry_run(api_http) if os.environ.get("DRY_RUN") in ("1", "true") else api_http
    return run(http, os.environ["BUNDLE_ID"], os.environ["VERSION"], os.environ["BUILD_NUMBER"], doc, time.sleep,
               external=external_from(os.environ.get("EXTERNAL", "")),
               keep_what_to_test=keep_from(os.environ.get("KEEP_WHAT_TO_TEST", "")))


if __name__ == "__main__":
    sys.exit(main())
