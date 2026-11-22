#!/usr/bin/env python3
"""Checks the DeckBridge website (#169) before anyone looks at it or it's published:
- every page exists, and every internal link and asset resolves
- robots.txt, sitemap.xml and llms.txt are at the root; the sitemap parses, each URL in it
  is under https://getdeckbridge.app/ and is a page in the site, and it lists every required page (PAGES); llms.txt starts with "# DeckBridge"
  and links every required page by its public URL
- nothing is loaded from another site (fonts, images, styles, scripts are all local); links out are fine,
  and so are <link rel="canonical"> and <link rel="alternate">. The one exception is the PostHog loader script
  (POSTHOG_LOADER), which website/analytics.js adds to count visits; the privacy page discloses it
- every page has a title and a meta description, and a page's canonical is its own URL; the home page links the LC6000 page (for/lc6000/, #268)
- every page loads the site's own analytics.js, and every mailto: link has a data-track (the click event it sends)
- no page, index.md or llms.txt still has a TODO(user) TestFlight placeholder (the public link is live)
- every <img> has an alt attribute (alt="" for a decorative one)
- every <script type="application/ld+json"> block parses as JSON
- no page title or main heading uses another company's name as the product's
- the privacy page says the app collects no data, and discloses the website's PostHog visit counts as
  showrecorder.app's does (PRIVACY_STATEMENTS)
- a sentence saying nothing goes to the network, that the app talks or sends only to Syndicate, or that nothing
  leaves the Mac names the display feed; the privacy page discloses the feed in the owner's wording (#632)
- the home page has an In the lab section with the owner's disclaimers; what it holds (the deck panel, the drawn jog
  display, a reflashed chip) is named nowhere else, and no page says how to flash anything (#647)
- once the site says 1.1 or later, the home page, index.md and llms.txt each name 1.1's features (#647)
- no other company's logo is in the site
- the whole site stays under 2 MB
Standard library only. Run: python3 -I scripts/check_site.py [website]   (exits 1 on any problem)
Tested by scripts/test_check_site.py."""
import html, json, os, re, sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from urllib.parse import urlsplit

PAGES = ["index.html", "support/index.html", "privacy/index.html", "capture/index.html",
         "for/lc6000/index.html"]  # /for/<controller>/: one page per supported controller (#268)
ROOT_FILES = ["robots.txt", "sitemap.xml", "llms.txt"]
SITE = "https://getdeckbridge.app/"
LLMS_HEADING = "# DeckBridge"
PRIVACY = "privacy/index.html"
HOME = "index.html"
CAPTURE_URL = SITE + "capture/"
PRIVACY_STATEMENTS = [
    "collects no data",  # the app
    # the website: cookieless PostHog (persistence memory, cookieless_mode always), worded as showrecorder.app's
    "posthog", "no cookies", "anonymous hash that changes every day", "does not keep the address",
    "counts clicks on a few links", "to have your visits removed, email",
    # the display feed (#632), in the owner's wording: what it sends, unencrypted, and where
    "display feed", "including track title and artist", "unencrypted to the one address you set on your local network",
    # the web capture (#190): it uploads nothing, and the analytics count only that one started and finished
    "web capture", "nothing is uploaded", "counts only that a capture started and finished",
]
OTHER_COMPANIES = ["Syndicate", "Denon"]
MAX_BYTES = 2_000_000
PLACEHOLDER = re.compile(r"TODO\(user\):\s*TestFlight", re.IGNORECASE)
TEXT_FILES = (".html", ".md", ".txt")
ANALYTICS = "analytics.js"  # at the site's root; every page loads it
POSTHOG_LOADER = "https://us-assets.i.posthog.com/static/array.js"  # allowed only as a <script src>
LINK_RELS = {"canonical", "alternate"}  # a <link> with only these rels points somewhere; any other rel loads it


def is_external(url):
    return url.startswith(("http:", "https:", "//"))


def skip(url):
    return url == "" or url.startswith(("#", "mailto:", "tel:", "data:"))


class Page(HTMLParser):
    """The parts of a page the checks need, in document order."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title, self.h1, self.description, self.canonical = None, None, None, None
        self.text = []
        self.refs = []  # (url, loaded): loaded is "script" for a <script src>, True for other resources, False for links
        self.scripts = []  # src of every <script src>
        self.untracked_mailto = []  # href of every mailto: link without a data-track
        self.images = []  # (src, alt) of every <img>
        self.no_alt = []  # src of every <img> without an alt attribute
        self.json_ld = []  # the text of each <script type="application/ld+json">
        self.controllers = []  # (data-controller, data-status) of each element that names one (#201), in order
        self._in = None
        self._ld = None
        self.footer_text = []  # the text inside <footer>
        self._footer = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "footer":
            self._footer += 1
        if tag in ("title", "h1"):
            self._in = tag
            setattr(self, tag, getattr(self, tag) or "")
        if tag == "meta" and (attrs.get("name") or "").lower() == "description":
            self.description = (attrs.get("content") or "").strip()
        if tag == "a" and attrs.get("href") is not None:
            self.refs.append((attrs["href"], False))
            if attrs["href"].lower().startswith("mailto:") and not attrs.get("data-track"):
                self.untracked_mailto.append(attrs["href"])
        if tag == "script" and attrs.get("src") is not None:
            self.scripts.append(attrs["src"])
        if tag == "link" and attrs.get("href") is not None:
            rels = (attrs.get("rel") or "").lower().split()
            if "canonical" in rels:
                self.canonical = attrs["href"]
            self.refs.append((attrs["href"], not rels or not set(rels) <= LINK_RELS))
        if tag == "script" and (attrs.get("type") or "").strip().lower() == "application/ld+json":
            self._ld = []
        if tag == "img":
            self.images.append((attrs.get("src") or "", attrs.get("alt") or ""))
        if attrs.get("data-controller") is not None:
            self.controllers.append((attrs["data-controller"], attrs.get("data-status") or ""))
        if tag == "img" and "alt" not in attrs:
            self.no_alt.append(attrs.get("src") or "")
        if attrs.get("src") is not None:
            self.refs.append((attrs["src"], "script" if tag == "script" else True))

    def handle_endtag(self, tag):
        if tag == "footer" and self._footer:
            self._footer -= 1
        if tag == self._in:
            self._in = None
        if tag == "script" and self._ld is not None:
            self.json_ld.append("".join(self._ld))
            self._ld = None

    def handle_data(self, data):
        if self._ld is not None:
            self._ld.append(data)
            return
        self.text.append(data)
        if self._footer:
            self.footer_text.append(data)
        if self._in:
            setattr(self, self._in, getattr(self, self._in) + data)


CSS_REFS = re.compile(r"""url\(\s*['"]?([^'")\s]+)['"]?\s*\)|@import\s+['"]([^'"]+)['"]""")
CSS_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
CSS_DATA_URI = re.compile(r"""url\(\s*(['"])data:.*?\1\s*\)""", re.DOTALL)  # an inline picture, with its own url(#id)s


def css_refs(css):
    """The url() and @import references a stylesheet makes, leaving out its comments and inline data: pictures."""
    return [a or b for a, b in CSS_REFS.findall(CSS_DATA_URI.sub("", CSS_COMMENT.sub("", css)))]


def target(root, file, url):
    """The file a relative URL on a page points to."""
    return os.path.normpath(os.path.join(os.path.dirname(os.path.join(root, file)), urlsplit(url).path))


def resolves(root, file, url):
    if urlsplit(url).path == "":
        return True
    target_ = target(root, file, url)
    if not target_.startswith(os.path.normpath(root)):
        return False
    if os.path.isdir(target_):
        target_ = os.path.join(target_, "index.html")
    return os.path.isfile(target_)


def check_refs(root, file, refs):
    out = []
    for url, loaded in refs:
        if skip(url):
            continue
        if is_external(url):
            if loaded and not (loaded == "script" and url == POSTHOG_LOADER):
                out.append(f"{file}: loads {url} from another site")
        elif not resolves(root, file, url):
            out.append(f"{file}: link to {url} doesn't resolve")
    return out


PRICE_QUESTION = "How much does DeckBridge cost?"

# Syndicate's maker, by its full name wherever the site names it, and in every page's footer disclaimer.
COMPANY = "Untitled Audio Syndicate Ltd."
BARE_COMPANY = re.compile(r"Untitled Audio(?! Syndicate Ltd\.)")


def company_problems(file, text):
    """A file that names Syndicate's maker any other way than "Untitled Audio Syndicate Ltd."."""
    return [f'{file}: names "Untitled Audio" without "Syndicate Ltd."'] if BARE_COMPANY.search(text) else []


# The version the site says is on TestFlight: CHANGELOG.md's newest release, in the text and the JSON-LD.
# DeckBridge's version as a statement ("Version 1.1.0 is in beta", "DeckBridge 1.1.0 on TestFlight"), not Syndicate's.
STATED_VERSION = re.compile(r'(?:\b(?:[Vv]ersion|DeckBridge)\s+(\d+\.\d+\.\d+)(?=\**\s+(?:is|on)\b)'
                            r'|"softwareVersion":\s*"(\d+\.\d+\.\d+)")')
RELEASE_HEADING = re.compile(r"^## (\d+\.\d+(?:\.\d+)?)\s*$", re.MULTILINE)


def latest_release(changelog):
    """CHANGELOG.md's newest release: its first "## x.y.z" heading."""
    found = RELEASE_HEADING.search(changelog)
    return found.group(1) if found else None


def version_problems(file, text, release):
    """Each place the file states a version other than the latest release."""
    return [f"{file}: says version {v}, not the latest release {release}"
            for v in ("".join(m) for m in STATED_VERSION.findall(text)) if v != release]


def json_ld_nodes(blocks):
    """Every object in the page's JSON-LD blocks, at any depth."""
    out = []
    def walk(node):
        if isinstance(node, dict):
            out.append(node)
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
    for block in blocks:
        try:
            walk(json.loads(block))
        except ValueError:
            pass  # reported by check_page
    return out


# A sentence that says nothing goes to the network (#632): with the display feed on, the deck in front goes,
# unencrypted, to the one address the DJ sets (ADR 0011), so the sentence must name the display feed.
NOTHING_TO_THE_NETWORK = re.compile(r'[^.!?"<>{}]*\bnothing\b[^.!?"<>{}]*\bnetwork\b[^.!?"<>{}]*[.!?]', re.IGNORECASE)


INLINE_TAG = re.compile(r"</?(?:a|strong|em|b|i|code|span|abbr)\b[^>]*>", re.IGNORECASE)


# A sentence that says the app talks or sends only to the controller and Syndicate, or that nothing leaves the Mac
# (#632): the display feed is the exception once it's on, so the sentence must name it.
ONLY_SYNDICATE = re.compile(r'[^.!?"<>{}]*\b(?:only (?:talks|sends)|sends [^.!?"<>{}]*\bonly to|nothing leaves your mac)\b'
                            r'[^.!?"<>{}]*[.!?]', re.IGNORECASE)
# A meta description's text, which search results show: read as a sentence of its own.
META_CONTENT = re.compile(r'<meta\s[^>]*(?:name|property)="(?:description|og:description|twitter:description)"[^>]*'
                          r'content="([^"]*)"', re.IGNORECASE)


# "In the lab" (#647): what needs hardware or firmware others can't get, on the home page in <section id="lab">, in
# index.md under "## In the lab", in llms.txt on a "- In the lab:" line. It says the owner's disclaimers; what it holds
# is named nowhere else, and no page says how to flash anything.
LAB_SECTION = re.compile(r'<section\b[^>]*\bid="lab"[^>]*>(.*?)</section>', re.S | re.I)
LAB_STATEMENTS = ["not part of the deckbridge app", "not offered for download",
                  "never includes or distributes denon's firmware", "no kit or firmware to download"]
LAB_ONLY = ["deck panel", "drawn jog display", "reflashed"]
FLASHING = ["bootloader", "dfu-util", "dfu mode", "flashing", "flash the", "flash it"]


# What 1.1 brings (#647), named on each product page, worded as the CHANGELOG (#648) and the What to Test do.
NEW_IN_1_1 = ["jog display", "transpose", "exact colors", "key display", "needle drop", "display feed"]
NEW_IN_1_1_FILES = ["index.html", "index.md", "llms.txt"]


def plain_words(text, markup=True):
    """Lowercased words, curly apostrophes made straight; HTML's tags dropped (only HTML's: Markdown's <autolinks> aren't)."""
    if markup:
        text = html.unescape(re.sub(r"<[^>]+>", " ", text))
    return " ".join(text.replace("\u2019", "'").lower().split())


def outside_lab(file, text):
    if file.endswith(".html"):
        return LAB_SECTION.sub(" ", text)
    if file.endswith(".md"):
        return re.sub(r"(?ms)^## In the lab\n.*?(?=^## |\Z)", "", text)
    return "\n".join(line for line in text.split("\n") if not line.startswith("- In the lab:"))


def lab_problems(file, text):
    markup = file.endswith(".html")
    outside = plain_words(outside_lab(file, text), markup)
    out = [f'{file}: names "{words}" outside In the lab' for words in LAB_ONLY if words in outside]
    said = plain_words(text, markup)
    return out + [f'{file}: says "{words}": no flashing instructions on the site' for words in FLASHING if words in said]


def network_problems(file, text):
    # Inline tags sit inside a sentence; any other tag ends one.
    plain = text
    if file.endswith(".html"):
        metas = ". ".join(META_CONTENT.findall(text))
        plain = html.unescape(metas + ". " + re.sub(r"<[^>]+>", ".", INLINE_TAG.sub(" ", text)))
    out = [f'{file}: says nothing goes to the network without naming the display feed: "{" ".join(m.group(0).split())}"'
           for m in NOTHING_TO_THE_NETWORK.finditer(plain) if "display feed" not in m.group(0).lower()]
    return out + [f'{file}: says the app sends only to Syndicate or nothing leaves the Mac without naming the display feed:'
                  f' "{" ".join(m.group(0).split())}"'
                  for m in ONLY_SYNDICATE.finditer(plain) if "display feed" not in m.group(0).lower()]


def check_price(file, blocks):
    """The app's price in the JSON-LD offers and the FAQ answer about cost agree: "free" for a price of 0."""
    nodes = json_ld_nodes(blocks)
    app = next((n for n in nodes if n.get("@type") == "SoftwareApplication"), None)
    offers = app.get("offers") if app else None
    if not (isinstance(offers, dict) and "price" in offers and "priceCurrency" in offers):
        return [f"{file}: the SoftwareApplication JSON-LD has no offers (price and priceCurrency)"]
    answer = next((str(n.get("acceptedAnswer", {}).get("text", "")) for n in nodes
                   if n.get("@type") == "Question" and n.get("name") == PRICE_QUESTION), None)
    if answer is None:
        return [f'{file}: the JSON-LD has no "{PRICE_QUESTION}" question']
    price = str(offers["price"])
    if float(price) == 0:
        if "free" not in answer.lower():
            return [f'{file}: the JSON-LD offers it free, but its answer to "{PRICE_QUESTION}" doesn\'t say free']
    elif price not in answer:
        return [f'{file}: the JSON-LD offers {price} {offers["priceCurrency"]}, but its answer to "{PRICE_QUESTION}" '
                f"doesn't say {price}"]
    return []


def check_page(root, file, text):
    page = Page()
    page.feed(text)
    out = []
    if not (page.title or "").strip():
        out.append(f"{file}: no <title>")
    if not page.description:
        out.append(f"{file}: no meta description")
    for part, words in (("title", page.title), ("h1", page.h1)):
        for name in OTHER_COMPANIES:
            if words and re.search(rf"\b{name}\b", words, re.IGNORECASE):
                out.append(f"{file}: the <{part}> names {name}")
    if file in PAGES and page.canonical is not None and page.canonical != page_url(file):
        out.append(f"{file}: its canonical is {page.canonical}, not {page_url(file)}")
    out += [f'{file}: <img src="{src}"> has no alt' for src in page.no_alt]
    if COMPANY not in " ".join(" ".join(page.footer_text).split()):
        out.append(f'{file}: the footer doesn\'t name "{COMPANY}"')
    # v1.1 ships the jog display: it's shown by the app's own renderer (img/jog-display-*), whose alt says what the
    # ring (the master clock) and the needle (the deck's bar) show; the old teaser art is gone.
    for src, alt in page.images:
        name = os.path.basename(urlsplit(src).path)
        if name == TEASER_ART:
            out.append(f"{file}: shows the v1.1 teaser art (img/{TEASER_ART}); use the renderer's images (img/jog-display-*)")
        elif name.startswith("jog-display-") and not ("ring" in alt.lower() and "needle" in alt.lower()):
            out.append(f"{file}: the alt of {src} doesn't say what the ring and the needle show")
    if not any(target(root, file, src) == os.path.join(os.path.normpath(root), ANALYTICS)
               for src in page.scripts if not is_external(src)):
        out.append(f"{file}: doesn't load {ANALYTICS}")
    out += [f'{file}: <a href="{href}"> has no data-track' for href in page.untracked_mailto]
    for n, block in enumerate(page.json_ld, 1):
        try:
            json.loads(block)
        except ValueError as e:
            out.append(f"{file}: JSON-LD block {n} doesn't parse: {e}")
    out += check_refs(root, file, page.refs)
    if file == HOME:
        # The FAQ points owners without the app to the web capture (#190), in its text and in the FAQPage JSON-LD.
        def links(folder):
            return any(not loaded and target(root, file, url) == os.path.normpath(os.path.join(root, folder))
                       for url, loaded in page.refs if not is_external(url) and not skip(url))
        if not links("capture"):
            out.append(f"{file}: doesn't link the web capture (capture/)")
        if not links("for/lc6000"):
            out.append(f"{file}: doesn't link the LC6000 page (for/lc6000/)")
        if not any(CAPTURE_URL in block for block in page.json_ld):
            out.append(f"{file}: its JSON-LD doesn't name {CAPTURE_URL}")
        out += check_price(file, page.json_ld)
    if file == HOME:
        lab = LAB_SECTION.search(text)
        if not lab:
            out.append(f'{file}: has no In the lab section (<section id="lab">)')
        else:
            said = plain_words(lab.group(1))
            out += [f'{file}: the In the lab section doesn\'t say "{words}"' for words in LAB_STATEMENTS if words not in said]
    if file == PRIVACY:
        said = " ".join(" ".join(page.text).split()).lower()
        out += [f'{file}: doesn\'t say "{words}"' for words in PRIVACY_STATEMENTS if words not in said]
    return out


def check_sitemap(root, files):
    try:
        tree = ET.parse(os.path.join(root, "sitemap.xml"))
    except ET.ParseError as e:
        return [f"sitemap.xml: doesn't parse as XML: {e}"]
    locs = [(el.text or "").strip() for el in tree.iter() if el.tag.rsplit("}", 1)[-1] == "loc"]
    if not locs:
        return ["sitemap.xml: lists no pages"]
    out, listed = [], set()
    for loc in locs:
        if not loc.startswith(SITE):
            out.append(f"sitemap.xml: {loc} isn't under {SITE}")
            continue
        path = urlsplit(loc).path.lstrip("/")
        if path == "" or path.endswith("/"):
            path += "index.html"
        if not (path.endswith(".html") and path in files):
            out.append(f"sitemap.xml: {loc} isn't a page in the site")
        listed.add(path)
    out += [f"sitemap.xml: doesn't list {page_url(page)}" for page in PAGES if page not in listed]
    return out


def page_url(page):
    """A required page's public URL: index.html -> https://getdeckbridge.app/, support/index.html -> .../support/."""
    return SITE + page.removesuffix("index.html")


CAPTURE_PROMPTS = "capture/prompts.json"
APP_PROMPTS = os.path.join("Packages", "ControllerBridgeKit", "Sources", "ControllerBridgeCapture", "Resources",
                           "capture-prompts-dj.json")


def check_capture_prompts(root, app_prompts):
    """The web capture walks the app's own prompts (#190): its copy must be the app's file, byte for byte."""
    site = os.path.join(root, CAPTURE_PROMPTS)
    if not os.path.isfile(site):
        return [f"{CAPTURE_PROMPTS}: missing; copy it from {app_prompts}"]
    with open(site, "rb") as a, open(app_prompts, "rb") as b:
        if a.read() != b.read():
            return [f"{CAPTURE_PROMPTS}: isn't the app's prompt list byte for byte; copy it from {app_prompts}"]
    return []


# A DeckBridge version on the site (#v1.1): "Version 1.0.1", "version 1.0.1 is on TestFlight", "DeckBridge 1.0.1". Three
# parts, and not in parentheses, so "Syndicate's mapping (version 0.3.7)" is free. A two-part "DeckBridge 1.2" is
# PLANNED_MENTION's: allowed only once the app has reached it (#652's audit: "from DeckBridge 1.2" for a 1.0.2 feature).
VERSION_MENTION = re.compile(r"(?:\b[Vv]ersion|\bDeckBridge) (\d+\.\d+\.\d+)(?![\d.]|\s*\))")
PLANNED_MENTION = re.compile(r"\bDeckBridge (\d+\.\d+)(?!\.?\d)")

# The capture's button before 1.1 (#652's audit): 1.1 replaced it with Help add it… and Controller not found?.
OLD_CAPTURE_BUTTON = "Help add a controller\u2026"

# The channel fader is the plain Needle Drop touch since #729 (before 1.1.0), and Shift seeks: never "Shift + Needle Drop"
# moving it, in a sentence, a heading or "Shift + Needle Drop on the channel fader".
SHIFT_FADER = re.compile(r"shift \+ needle drop[^.<]{0,40}channel fader", re.IGNORECASE)


TEASER_ART = "jog-art.png"

# "Coming in v1.1": a feature promised for a version, which can't still be coming once that version ships.
COMING = re.compile(r"coming in v(\d+(?:\.\d+){1,2})", re.IGNORECASE)


def version_tuple(version):
    parts = [int(p) for p in version.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


# The web capture's app_version, "web x.y.z" (#190): the site's version too.
CAPTURE_PAGE_JS = "capture/capture-page.js"
CAPTURE_VERSION = re.compile(r'APP_VERSION\s*=\s*"web (\d+\.\d+\.\d+)"')


def app_version(root):
    """The home page JSON-LD's SoftwareApplication softwareVersion: the one version the site may name."""
    path = os.path.join(root, HOME)
    if not os.path.isfile(path):
        return None
    page = Page()
    with open(path, encoding="utf-8") as f:
        page.feed(f.read())
    def find(node):
        if isinstance(node, dict):
            if node.get("@type") == "SoftwareApplication" and isinstance(node.get("softwareVersion"), str):
                return node["softwareVersion"]
            return next((v for v in map(find, node.values()) if v), None)
        if isinstance(node, list):
            return next((v for v in map(find, node) if v), None)
        return None
    for block in page.json_ld:
        try:
            version = find(json.loads(block))
        except ValueError:
            continue
        if version:
            return version
    return None


CONTROLLERS = "controllers.json"
CONTROLLER_STATUSES = ["supported", "in progress"]


def load_controllers(root):
    """controllers.json (#201): the one list of controllers the page and its JSON-LD show. Each has a name and a maker,
    and an optional status, "supported" (the default) or "in progress". Returns (entries, problems)."""
    path = os.path.join(root, CONTROLLERS)
    if not os.path.isfile(path):
        return [], [f"{CONTROLLERS}: missing"]
    try:
        with open(path, encoding="utf-8") as f:
            entries = json.load(f)
    except ValueError as e:
        return [], [f"{CONTROLLERS}: doesn't parse as JSON: {e}"]
    if not isinstance(entries, list):
        return [], [f"{CONTROLLERS}: should be a list"]
    out = []
    for n, entry in enumerate(entries):
        entry = entry if isinstance(entry, dict) else {}
        if not (isinstance(entry.get("name"), str) and entry["name"] and isinstance(entry.get("maker"), str) and entry["maker"]):
            out.append(f"{CONTROLLERS}[{n}]: needs a name and a maker")
        status = entry.get("status", "supported")
        if status not in CONTROLLER_STATUSES:
            out.append(f'{CONTROLLERS}[{n}]: status "{status}" isn\'t one of {", ".join(CONTROLLER_STATUSES)}')
    if not any(isinstance(e, dict) and e.get("name") and e.get("status", "supported") == "supported" for e in entries):
        out.append(f"{CONTROLLERS}: lists no supported controller")
    return entries, out


def described(pairs):
    return ", ".join(f"{name}: {status}" for name, status in pairs) or "none"


def check_home_controllers(root, controllers):
    """The home page lists exactly controllers.json, in order, with each status (#201)."""
    wanted = [(f"{c['maker']} {c['name']}", c.get("status", "supported")) for c in controllers]
    page = Page()
    with open(os.path.join(root, HOME), encoding="utf-8") as f:
        page.feed(f.read())
    out = []
    if page.controllers != wanted:
        out.append(f"{HOME}: its controller list ({described(page.controllers)}) isn't {CONTROLLERS}'s ({described(wanted)})")
    # The FAQPage JSON-LD's answer names every supported controller, so search and answer engines read the same list.
    answer = None
    for block in page.json_ld:
        try:
            answer = answer or questions(json.loads(block)).get(CONTROLLERS_QUESTION)
        except ValueError:
            pass  # reported by check_page
    if answer is None:
        out.append(f'{HOME}: the JSON-LD has no "{CONTROLLERS_QUESTION}" question')
    else:
        for c in controllers:
            if c.get("status", "supported") == "supported" and c["name"] not in answer:
                out.append(f'{HOME}: the JSON-LD answer to "{CONTROLLERS_QUESTION}" doesn\'t name {c["name"]}')
    return out


CONTROLLERS_QUESTION = "Which controllers does DeckBridge support?"


def questions(node):
    """Every JSON-LD Question's name and its accepted answer's text, anywhere in the block."""
    found = {}
    if isinstance(node, dict):
        if node.get("@type") == "Question" and isinstance(node.get("acceptedAnswer"), dict):
            found[node.get("name")] = str(node["acceptedAnswer"].get("text", ""))
        for value in node.values():
            found.update(questions(value))
    elif isinstance(node, list):
        for value in node:
            found.update(questions(value))
    return found


def problems(root, app_prompts=None, release=None):
    """`app_prompts`: the app's capture prompt list (#190), which the site's capture/prompts.json must equal byte for
    byte; None skips the check (a site checked on its own). `release`: CHANGELOG.md's newest, the version the site must
    state; None skips it."""
    files = sorted(os.path.relpath(os.path.join(d, f), root).replace(os.sep, "/")
                   for d, _, names in os.walk(root) for f in names)
    out = [f"{page}: missing" for page in PAGES + ROOT_FILES if page not in files]
    app_version = globals()["app_version"](root)
    if HOME in files and not app_version:
        out.append(f"{HOME}: the JSON-LD has no SoftwareApplication softwareVersion")
    controllers, controller_problems = load_controllers(root)
    out += controller_problems
    if not controller_problems and HOME in files:
        out += check_home_controllers(root, controllers)
    size = 0
    for file in files:
        path = os.path.join(root, file)
        size += os.path.getsize(path)
        lower = os.path.basename(file).lower()
        if "logo" in lower and any(name.lower() in lower for name in OTHER_COMPANIES):
            out.append(f"{file}: looks like another company's logo")
        if file.endswith(TEXT_FILES):
            with open(path, encoding="utf-8") as f:
                text = f.read()
            out += company_problems(file, text)
            out += network_problems(file, text)
            out += lab_problems(file, text)
            if file in NEW_IN_1_1_FILES and app_version and version_tuple(app_version) >= (1, 1):
                said = plain_words(text, file.endswith(".html"))
                out += [f'{file}: doesn\'t name 1.1\'s "{words}"' for words in NEW_IN_1_1 if words not in said]
            if release:
                out += version_problems(file, text, release)
            if PLACEHOLDER.search(text):
                out.append(f"{file}: still has a TODO(user) TestFlight placeholder")
            if app_version:
                shipped = version_tuple(app_version)
                for coming in sorted(set(m.lower() for m in COMING.findall(text))):
                    if version_tuple(coming) <= shipped:
                        out.append(f"{file}: says coming in v{coming}, but the app is {app_version}")
                for mentioned in sorted(set(VERSION_MENTION.findall(text)) - {app_version}):
                    out.append(f"{file}: says DeckBridge {mentioned}, but the app's softwareVersion is {app_version}")
                for planned in sorted(set(PLANNED_MENTION.findall(text))):
                    if version_tuple(planned) > shipped:
                        out.append(f"{file}: says DeckBridge {planned}, a version that hasn't shipped (the app is {app_version})")
            if SHIFT_FADER.search(plain_words(text, file.endswith(".html"))):
                out.append(f"{file}: says Shift + Needle Drop moves the channel fader; since #729 the plain touch does, "
                           "and Shift seeks")
            if OLD_CAPTURE_BUTTON in text:
                out.append(f"{file}: names the button {OLD_CAPTURE_BUTTON}, which 1.1 replaced with Help add it\u2026 "
                           "and Controller not found?")
            if file.endswith(".html"):
                out += check_page(root, file, text)
        if file == CAPTURE_PAGE_JS and app_version:
            with open(path, encoding="utf-8") as f:
                for written in CAPTURE_VERSION.findall(f.read()):
                    if written != app_version:
                        out.append(f"{file}: writes captures as web {written}, but the app's softwareVersion is {app_version}")
        elif file.endswith(".css"):
            with open(path, encoding="utf-8") as f:
                css = f.read()
            out += check_refs(root, file, [(url, True) for url in css_refs(css)])
    if "llms.txt" in files:
        with open(os.path.join(root, "llms.txt"), encoding="utf-8") as f:
            llms = f.read()
        if llms.split("\n", 1)[0].rstrip() != LLMS_HEADING:
            out.append(f'llms.txt: doesn\'t start with "{LLMS_HEADING}"')
        out += [f"llms.txt: doesn't link {page_url(page)}" for page in PAGES if f"]({page_url(page)})" not in llms]
    if "sitemap.xml" in files:
        out += check_sitemap(root, files)
    if app_prompts is not None:
        out += check_capture_prompts(root, app_prompts)
    if size > MAX_BYTES:
        out.append(f"the site is {size / 1_000_000:.1f} MB, over 2 MB")
    return out


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "website")
    # The app's prompt list, when this repo has it (on the site branch before main is merged in, it may not).
    app = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", APP_PROMPTS)
    changelog = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "CHANGELOG.md")
    release = None
    if os.path.isfile(changelog):
        with open(changelog, encoding="utf-8") as f:
            release = latest_release(f.read())
    found = problems(root, app_prompts=app if os.path.isfile(app) else None, release=release)
    for problem in found:
        print("FAIL:", problem)
    print("== Site check passed" if not found else f"== {len(found)} site problem(s)")
    sys.exit(1 if found else 0)


if __name__ == "__main__":
    main()
