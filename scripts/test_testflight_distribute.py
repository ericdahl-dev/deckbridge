#!/usr/bin/env python3
"""Tests for scripts/testflight_distribute.py against a fake App Store Connect API. No network, no keys.
Run: python3 -I scripts/test_testflight_distribute.py"""
import contextlib, io, os, sys, tempfile, unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import testflight_distribute as td

BUNDLE = "dev.ericdahl.ControllerBridge"


class FakeASC:
    """App Store Connect in memory: the app, its builds, groups, localizations and review state."""

    def __init__(self, builds=None):
        # Each build is (version, build number, states the poll sees in turn).
        self.builds = builds if builds is not None else [("1.0.0", "41.1", ["VALID"]), ("1.0.1", "42.1", ["VALID"])]
        self.calls = []
        self.localizations = {}  # locale -> (id, whatsNew)
        self.groups = {"Internal": "g-int", "Syndicate": "g-ext", "Syndicate Friends": "g-other"}
        self.in_group = set()
        self.all_builds = set()  # internal groups that get every build automatically
        self.group_conflict = False
        self.review_detail = {"contactFirstName": "A", "contactLastName": "B", "contactPhone": "+1 555 0100",
                              "contactEmail": "beta@example.com"}
        self.app_localizations = [{"locale": "en-US", "description": "A bridge.", "feedbackEmail": "beta@example.com"}]
        self.submission = None
        self.submit_reply = None  # (status, body) to answer the POST with, instead of creating one

    def http(self, method, path, body=None, query=None):
        self.calls.append((method, path, body, query))
        if method == "GET" and path == "/apps/app1/betaAppReviewDetail":
            return 200, {"data": {"id": "app1", "attributes": self.review_detail}}
        if method == "GET" and path == "/apps/app1/betaAppLocalizations":
            return 200, {"data": [{"id": f"al{i}", "attributes": a} for i, a in enumerate(self.app_localizations)]}
        if method == "GET" and path == "/betaAppReviewSubmissions":
            # The list filtered by build: empty when there's none, never a 404 for "none".
            assert query["filter[build]"] == "build1"
            return 200, {"data": [self.submission] if self.submission else []}
        if method == "POST" and path == "/betaAppReviewSubmissions":
            assert body == {"data": {"type": "betaAppReviewSubmissions",
                                     "relationships": {"build": {"data": {"type": "builds", "id": "build1"}}}}}
            if self.submit_reply:
                return self.submit_reply
            self.submission = {"id": "sub1", "attributes": {"betaReviewState": "WAITING_FOR_REVIEW"}}
            return 201, {"data": self.submission}
        if method == "GET" and path == "/betaGroups":
            assert query["filter[app]"] == "app1"
            # The API's name filter matches partly, as App Store Connect's does.
            return 200, {"data": [{"id": gid, "attributes": {"name": name, "isInternalGroup": gid == "g-int",
                                                             "hasAccessToAllBuilds": gid in self.all_builds}}
                                  for name, gid in self.groups.items() if query["filter[name]"] in name]}
        if method == "GET" and path.startswith("/betaGroups/") and path.endswith("/relationships/builds"):
            gid = path.split("/")[2]
            return 200, {"data": [{"type": "builds", "id": "build1"}] if gid in self.in_group else []}
        if method == "POST" and path.startswith("/betaGroups/") and path.endswith("/relationships/builds"):
            gid = path.split("/")[2]
            assert body == {"data": [{"type": "builds", "id": "build1"}]}
            if self.group_conflict:
                return 409, {"errors": [{"code": "ENTITY_ERROR", "detail": "The build is already in the group."}]}
            self.in_group.add(gid)
            return 204, {}
        if method == "GET" and path == "/builds/build1/betaBuildLocalizations":
            return 200, {"data": [{"id": lid, "attributes": {"locale": locale, "whatsNew": text}}
                                  for locale, (lid, text) in self.localizations.items()]}
        if method == "POST" and path == "/betaBuildLocalizations":
            attributes = body["data"]["attributes"]
            assert body["data"]["relationships"]["build"]["data"] == {"type": "builds", "id": "build1"}
            self.localizations[attributes["locale"]] = ("loc-new", attributes["whatsNew"])
            return 201, {"data": {"id": "loc-new"}}
        if method == "PATCH" and path.startswith("/betaBuildLocalizations/"):
            lid = path.split("/")[2]
            locale = next(k for k, (i, _) in self.localizations.items() if i == lid)
            assert body["data"] == {"type": "betaBuildLocalizations", "id": lid, "attributes": body["data"]["attributes"]}
            self.localizations[locale] = (lid, body["data"]["attributes"]["whatsNew"])
            return 200, {"data": {"id": lid}}
        if method == "GET" and path == "/apps":
            assert query["filter[bundleId]"] == BUNDLE
            return 200, {"data": [{"id": "app1", "attributes": {"bundleId": BUNDLE}}]}
        if method == "GET" and path == "/builds":
            assert query["filter[app]"] == "app1"
            assert query["filter[preReleaseVersion.platform]"] == "MAC_OS"
            found = []
            for index, (version, number, states) in enumerate(self.builds):
                if version == query["filter[preReleaseVersion.version]"] and number == query["filter[version]"]:
                    state = states.pop(0) if len(states) > 1 else states[0]
                    if state is not None:
                        found.append({"id": f"build{index}", "attributes": {"version": number, "processingState": state}})
            return 200, {"data": found}
        raise AssertionError(f"unexpected call {method} {path}")


class Recorder:
    def __init__(self):
        self.slept = []

    def sleep(self, seconds):
        self.slept.append(seconds)


class FindBuildTests(unittest.TestCase):
    def test_finds_the_build_by_version_and_build_number(self):
        api = FakeASC(builds=[("1.0.0", "41.1", ["VALID"]), ("1.0.1", "42.1", ["VALID"])])
        build = td.find_build(api.http, BUNDLE, "1.0.1", "42.1", sleep=Recorder().sleep)
        self.assertEqual(build, "build1")

    def test_matches_the_dotted_build_number_exactly(self):
        # The build number is run.attempt: 42.10 is a different build from 42.1, even if the API returns both.
        def http(method, path, body=None, query=None):
            if path == "/apps":
                return 200, {"data": [{"id": "app1", "attributes": {"bundleId": BUNDLE}}]}
            return 200, {"data": [{"id": "b10", "attributes": {"version": "42.10", "processingState": "VALID"}},
                                  {"id": "b1", "attributes": {"version": "42.1", "processingState": "VALID"}}]}
        self.assertEqual(td.find_build(http, BUNDLE, "1.0.1", "42.1", sleep=Recorder().sleep), "b1")


class ProcessingPollTests(unittest.TestCase):
    def test_waits_while_the_build_is_missing_then_processing(self):
        # Right after the upload the build isn't listed yet, then it processes, then it's valid.
        api = FakeASC(builds=[("1.0.1", "42.1", [None, "PROCESSING", "PROCESSING", "VALID"])])
        clock = Recorder()
        self.assertEqual(td.find_build(api.http, BUNDLE, "1.0.1", "42.1", sleep=clock.sleep), "build0")
        self.assertEqual(clock.slept, [td.POLL_SECONDS] * 3)

    def test_a_failed_or_invalid_build_stops_with_its_state(self):
        for state in ("FAILED", "INVALID"):
            api = FakeASC(builds=[("1.0.1", "42.1", ["PROCESSING", state])])
            with self.assertRaisesRegex(td.DistributeError, state):
                td.find_build(api.http, BUNDLE, "1.0.1", "42.1", sleep=Recorder().sleep)

    def test_gives_up_after_the_timeout(self):
        api = FakeASC(builds=[("1.0.1", "42.1", ["PROCESSING"])])
        clock = Recorder()
        with self.assertRaisesRegex(td.DistributeError, "still PROCESSING"):
            td.find_build(api.http, BUNDLE, "1.0.1", "42.1", sleep=clock.sleep, timeout=300)
        self.assertEqual(sum(clock.slept), 300)


DOC = """# TestFlight: What to test

Paste this into the build's "What to Test".

---

DeckBridge 1.0.1 has a new look.

- Try Settings.
"""


class WhatToTestTests(unittest.TestCase):
    def test_the_text_is_everything_after_the_rule(self):
        self.assertEqual(td.what_to_test(DOC), "DeckBridge 1.0.1 has a new look.\n\n- Try Settings.")

    def test_wrapped_lines_join_so_testers_see_whole_sentences(self):
        # TestFlight keeps line breaks; the doc is wrapped at 120 columns with indented continuations.
        doc = "# T\n\n---\n\nFirst paragraph\nwraps here.\n\n- A bullet that\n  wraps too.\n- Short.\n"
        self.assertEqual(td.what_to_test(doc), "First paragraph wraps here.\n\n- A bullet that wraps too.\n- Short.")

    def test_creates_the_en_us_text_when_the_build_has_none(self):
        api = FakeASC()
        td.set_what_to_test(api.http, "build1", "New look.")
        self.assertEqual(api.localizations, {"en-US": ("loc-new", "New look.")})

    def test_updates_the_text_on_a_rerun(self):
        api = FakeASC()
        api.localizations = {"en-US": ("loc1", "Old text.")}
        td.set_what_to_test(api.http, "build1", "New look.")
        self.assertEqual(api.localizations, {"en-US": ("loc1", "New look.")})
        self.assertFalse([c for c in api.calls if c[0] == "POST"])

    def test_keeps_an_existing_text_when_asked_to_keep(self):
        # #312: re-sending an older build by hand keeps its own notes, not today's doc.
        api = FakeASC()
        api.localizations = {"en-US": ("loc1", "1.0.1's notes.")}
        td.set_what_to_test(api.http, "build1", "1.1.0's notes.", keep=True)
        self.assertEqual(api.localizations, {"en-US": ("loc1", "1.0.1's notes.")})
        self.assertFalse([c for c in api.calls if c[0] in ("POST", "PATCH")])

    def test_keep_still_writes_a_build_that_has_no_text(self):
        api = FakeASC()
        td.set_what_to_test(api.http, "build1", "New look.", keep=True)
        self.assertEqual(api.localizations, {"en-US": ("loc-new", "New look.")})

    def test_the_environment_switch_for_keeping(self):
        self.assertTrue(td.external_from("1"))
        self.assertTrue(td.keep_from("1"))
        self.assertFalse(td.keep_from(""))


class GroupTests(unittest.TestCase):
    def test_adds_the_build_to_each_group_found_by_its_exact_name(self):
        api = FakeASC()
        td.add_to_group(api.http, "app1", "build1", "Syndicate")
        td.add_to_group(api.http, "app1", "build1", "Internal")
        self.assertEqual(api.in_group, {"g-ext", "g-int"})

    def test_a_missing_group_names_itself(self):
        api = FakeASC()
        with self.assertRaisesRegex(td.DistributeError, "No beta group named \"Testers\""):
            td.add_to_group(api.http, "app1", "build1", "Testers")

    def test_a_build_already_in_the_group_is_not_added_again(self):
        api = FakeASC()
        api.in_group = {"g-int"}
        td.add_to_group(api.http, "app1", "build1", "Internal")
        self.assertFalse([c for c in api.calls if c[0] == "POST"])

    def test_an_internal_group_that_gets_every_build_is_left_alone(self):
        api = FakeASC()
        api.all_builds = {"g-int"}
        td.add_to_group(api.http, "app1", "build1", "Internal")
        self.assertFalse([c for c in api.calls if c[0] == "POST"])

    def test_a_refused_add_fails_with_the_api_detail(self):
        api = FakeASC()
        api.group_conflict = True
        with self.assertRaisesRegex(td.DistributeError, "already in the group"):
            td.add_to_group(api.http, "app1", "build1", "Syndicate")


class ReviewTests(unittest.TestCase):
    def posts(self, api):
        return [c for c in api.calls if c[0] == "POST" and c[1] == "/betaAppReviewSubmissions"]

    def test_submits_the_build_for_beta_app_review(self):
        api = FakeASC()
        td.submit_for_review(api.http, "app1", "build1")
        self.assertEqual(api.submission["attributes"]["betaReviewState"], "WAITING_FOR_REVIEW")
        self.assertEqual(len(self.posts(api)), 1)

    def test_a_build_already_submitted_is_not_submitted_again(self):
        api = FakeASC()
        api.submission = {"id": "sub0", "attributes": {"betaReviewState": "IN_REVIEW"}}
        td.submit_for_review(api.http, "app1", "build1")
        self.assertEqual(self.posts(api), [])

    def test_a_conflict_saying_already_submitted_counts_as_done(self):
        api = FakeASC()
        api.submit_reply = (409, {"errors": [{"code": "ENTITY_ERROR.STATE_ERROR", "detail": "Build already submitted for review."}]})
        td.submit_for_review(api.http, "app1", "build1")

    def test_missing_contact_details_stop_before_submitting_and_say_what_to_fill_in(self):
        api = FakeASC()
        api.review_detail = dict(api.review_detail, contactPhone=None)
        with self.assertRaisesRegex(td.TestInformationMissing, "Test Information"):
            td.submit_for_review(api.http, "app1", "build1")
        self.assertEqual(self.posts(api), [])

    def test_a_missing_beta_description_or_feedback_email_stops_too(self):
        api = FakeASC()
        api.app_localizations = [{"locale": "en-US", "description": "", "feedbackEmail": "beta@example.com"}]
        with self.assertRaisesRegex(td.TestInformationMissing, "Beta App Description"):
            td.submit_for_review(api.http, "app1", "build1")

    def test_an_api_error_about_the_review_details_gets_the_same_message(self):
        api = FakeASC()
        api.submit_reply = (422, {"errors": [{"code": "ENTITY_ERROR.RELATIONSHIP.INVALID",
                                              "detail": "Beta App Review Information is missing a contact email."}]})
        with self.assertRaisesRegex(td.TestInformationMissing, "Test Information"):
            td.submit_for_review(api.http, "app1", "build1")


class ReviewErrorTests(unittest.TestCase):
    def test_an_unrelated_error_mentioning_contact_is_not_missing_test_information(self):
        # #312: "contact" alone matched too much.
        api = FakeASC()
        api.submit_reply = (500, {"errors": [{"code": "UNEXPECTED_ERROR", "detail": "Please contact Apple Developer Support."}]})
        with self.assertRaises(td.DistributeError) as caught:
            td.submit_for_review(api.http, "app1", "build1")
        self.assertNotIsInstance(caught.exception, td.TestInformationMissing)


class RunTests(unittest.TestCase):
    """The whole run, as the release workflow calls it."""

    def run_distribute(self, api, external=True):
        doc = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False)
        doc.write(DOC); doc.close()
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = td.run(api.http, BUNDLE, "1.0.1", "42.1", doc.name, sleep=Recorder().sleep, external=external)
        return code, out.getvalue() + err.getvalue()

    def test_internal_only_by_default_never_touches_the_external_group_or_review(self):
        # #244: a plain tag is for internal testers. Not the Syndicate group, not Beta App Review, not even a read.
        api = FakeASC()
        doc = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False)
        doc.write(DOC); doc.close()
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = td.run(api.http, BUNDLE, "1.0.1", "42.1", doc.name, sleep=Recorder().sleep)
        self.assertEqual(code, 0)
        self.assertEqual([(m, p) for m, p, _, _ in api.calls if m != "GET"],
                         [("POST", "/betaBuildLocalizations"), ("POST", "/betaGroups/g-int/relationships/builds")])
        self.assertFalse([c for c in api.calls if "g-ext" in c[1] or "betaAppReview" in c[1]
                          or (c[3] or {}).get("filter[name]") == td.EXTERNAL_GROUP])
        self.assertNotIn("g-ext", api.in_group)
        self.assertIn("Internal only", out.getvalue())

    def test_the_environment_switch_reads_external_only_when_set(self):
        self.assertFalse(td.external_from(""))
        self.assertFalse(td.external_from("0"))
        self.assertFalse(td.external_from("false"))
        self.assertTrue(td.external_from("1"))
        self.assertTrue(td.external_from("true"))

    def test_distributes_in_order_what_to_test_internal_external_review(self):
        api = FakeASC()
        code, out = self.run_distribute(api)
        self.assertEqual(code, 0)
        steps = [(m, p) for m, p, _, _ in api.calls if m != "GET"]
        self.assertEqual(steps, [("POST", "/betaBuildLocalizations"), ("POST", "/betaGroups/g-int/relationships/builds"),
                                 ("POST", "/betaGroups/g-ext/relationships/builds"), ("POST", "/betaAppReviewSubmissions")])
        self.assertEqual(api.localizations["en-US"][1], "DeckBridge 1.0.1 has a new look.\n\n- Try Settings.")

    def test_a_rerun_changes_nothing_new(self):
        api = FakeASC()
        self.run_distribute(api)
        api.calls.clear()
        code, _ = self.run_distribute(api)
        self.assertEqual(code, 0)
        self.assertEqual([c for c in api.calls if c[0] == "POST"], [])

    def test_missing_test_information_still_gives_internal_testers_the_build_then_fails(self):
        api = FakeASC()
        api.review_detail = {}
        code, out = self.run_distribute(api)
        self.assertNotEqual(code, 0)
        self.assertIn("g-int", api.in_group)
        self.assertIn("Test Information", out)
        self.assertFalse([c for c in api.calls if c[1] == "/betaAppReviewSubmissions" and c[0] == "POST"])

    def test_a_dry_run_reads_everything_and_changes_nothing(self):
        api = FakeASC()
        doc = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False)
        doc.write(DOC); doc.close()
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = td.run(td.dry_run(api.http), BUNDLE, "1.0.1", "42.1", doc.name, sleep=Recorder().sleep, external=True)
        self.assertEqual(code, 0)
        self.assertEqual([c for c in api.calls if c[0] != "GET"], [])
        self.assertIn("dry run: would POST /betaAppReviewSubmissions", out.getvalue())


if __name__ == "__main__":
    unittest.main()
