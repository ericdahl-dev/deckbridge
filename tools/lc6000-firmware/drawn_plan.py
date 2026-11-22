#!/usr/bin/env python3
"""The drawn wizard's plan (#567): every decision of `flash-day.sh drawn` in one place. The facts so far in, the next
step out; the shell only does what it's told (dfu-util, the keyboard) and records the result.

  python3 -I drawn_plan.py begin PLAN.json CURRENT.dfu UPPER.dfu OWNER.dfu RECORD.json WORK [REMEMBERED.dfu [LAST.json]]
                                                  CURRENT empty: found from the app read (#603)
  python3 -I drawn_plan.py next PLAN.json         one action, its fields separated by tabs
  python3 -I drawn_plan.py record PLAN.json KEY VALUE
  python3 -I drawn_plan.py devices LISTING        the stock wizard's look: one PATH, or stop WHY
  python3 -I drawn_plan.py find-record UPPER.dfu OWNER.dfu   the build record the kit left beside them: one PATH, or ask WHY
  python3 -I drawn_plan.py find-files WORK UPPER OWNER  B and the owner's image (UPPER, OWNER: remembered, or empty):
                                                        one UPPER OWNER RECORD, or ask WHY

Actions:
  ask KEY QUESTION                 a y/N question; record y or n
  type KEY WORD PROMPT             a typed word (FLASH, REWRITE, NO PROBE); record what was typed
  update-mode                      put the display chip in update mode; record ok or failed
  list OUT KEY                     dfu-util -l into OUT; record its path
  read AREA DFU_PATH OUT KEY       dfu-util -U of app, upper or options into OUT; record OUT, or failed
  write AREA DFU_PATH IMAGE KEY    dfu-util -D of IMAGE; record its exit code
  power-cycle                      the owner power-cycles; record ok or failed
  skip KEY TEXT                    say TEXT; record seen
  stop REASON                      say REASON and the way back
  done

Freshness: every write rests on a read made in this run, after update mode was entered; a fact from an earlier run
or from before update mode authorizes nothing, and the read is asked for again.
Standard library only; nothing here talks to the unit."""
import contextlib, io, json, os, sys, types, uuid

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))  # -I leaves this folder off sys.path (#468)
import build_record  # noqa: E402
import build_upper_dfu  # noqa: E402
import dfupatch  # noqa: E402
import drawn_flash  # noqa: E402

# Every step `next` can ask for: the shell handles exactly these.
ACTIONS = ("ask", "type", "update-mode", "list", "read", "write", "power-cycle", "skip", "stop", "done")

DISPLAY_LAYOUT = "/0x08000000/04*016Kg,01*064Kg,07*128Kg"  # 1 MB, single bank: the display chip (#432)
TOP_PANEL_LAYOUT = "/0x08000000/04*016Kg,01*064Kg,01*128Kg"  # 256 KB: the top panel chip (#434)


# MARK: the plan file

def begin(path, current, upper, owner, record, work, remembered="", last_record=""):
    """A new run: the owner's files and the blocks' build record (#593), and no facts. A plan file from an earlier run
    is replaced, never continued. CURRENT empty: the image the chip runs now is found from the read (#603), and
    REMEMBERED (the last run's) is one of the candidates. LAST_RECORD: last run's build record, when it's another
    build than this one, for the word screens."""
    plan = {"run": uuid.uuid4().hex[:12],
            "files": {"current": current, "upper": upper, "owner": owner, "record": record, "remembered": remembered,
                      "last_record": last_record},
            "work": work, "seq": 0, "facts": {}}
    save(path, plan)


def load(path):
    with open(path) as f:
        return json.load(f)


def save(path, plan):
    with open(path, "w") as f:
        json.dump(plan, f, indent=1)


def record(path, key, value):
    plan = load(path)
    plan["seq"] += 1
    plan["facts"][key] = {"value": value, "run": plan["run"], "seq": plan["seq"]}
    save(path, plan)


def fact(plan, key):
    """A fact of this run, or None."""
    entry = plan["facts"].get(key)
    return entry["value"] if entry and entry["run"] == plan["run"] else None


def fresh(plan, key):
    """A read made in this run after update mode was entered: the only kind a write may rest on."""
    entry, entered = plan["facts"].get(key), plan["facts"].get("update_mode")
    return (entry is not None and entered is not None and entry["run"] == plan["run"] == entered["run"]
            and entered["value"] == "ok" and entry["seq"] > entered["seq"] and entry["value"] != "failed")


# MARK: the judges, from drawn_flash.py and dfupatch.py, as values

def judged(function, **arguments):
    """(True, what it printed) or (False, why it refused)."""
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            function(types.SimpleNamespace(**arguments))
    except (dfupatch.Refused, OSError) as error:
        return False, str(error)
    return True, out.getvalue().strip()


def checked(plan, name, function, files):
    """`judged`, remembered in the plan by the files' contents: a judgment of files (the owner's, or a read) depends
    only on what they hold, so a changed file is judged again and an unchanged one isn't re-read (dfupatch's verify and
    compare walk all 480 KB). Keyed by each argument's name and content, so two files can't swap places unnoticed."""
    import hashlib
    digest = hashlib.sha256()
    for argument, path in sorted(files.items()):
        digest.update(argument.encode() + b"\0")
        try:
            with open(path, "rb") as f:
                digest.update(hashlib.sha256(f.read()).digest())
        except OSError:
            digest.update(b"unreadable")   # the judge itself says why

    key = f"{name}:{digest.hexdigest()}"
    cache = plan.setdefault("checks", {})
    if key not in cache:
        cache[key] = judged(function, **files)
    return tuple(cache[key])


def devices(listing_path):
    """The DFU devices dfu-util -l saw: {path: [alt names]}, 0483:df11 only."""
    import re
    found = {}
    with open(listing_path) as f:
        for line in f:
            if "Found DFU" not in line or "[0483:df11]" not in line.lower():
                continue
            path = re.search(r'path="([^"]*)"', line)
            name = re.search(r'name="([^"]*)"', line)
            if path:
                found.setdefault(path.group(1), []).append(name.group(1) if name else "")
    return found


def find_record(upper, owner):
    """The build record the kit tools left beside the two .dfu files (#593): ("one", path) when there's exactly one
    record, the same copy beside both counting once; else ("ask", why). Finding it judges nothing: the plan does."""
    found = {}
    for dfu in (upper, owner):
        path = build_record.carried(dfu)
        try:
            with open(path, "rb") as f:
                found.setdefault(f.read(), path)
        except OSError:
            continue
    if len(found) == 1:
        return ("one", next(iter(found.values())))
    if found:
        return ("ask", "The build records beside the two .dfu files differ: they're from different builds.")
    return ("ask", "No build record beside the two .dfu files.")


def built_at(record_path):
    """When the build was made: the record's own time (#603), else when the record file was written."""
    try:
        with open(record_path) as f:
            built = json.load(f).get("built")
        if isinstance(built, (int, float)):
            return built
    except (OSError, ValueError, AttributeError):
        pass
    try:
        return os.path.getmtime(record_path)
    except OSError:
        return None


def find_files(work, upper="", owner=""):
    """Block B's .dfu and the owner's image, found so the owner isn't asked (#603): ("one", upper, owner, record,
    last run's record when it's another build, else ""), or ("ask", why). The newest build in WORK the kit tools left
    (each .dfu with its record beside it, the two records the same) wins: the normal rewrite is "rebuild, then
    flash", and a silent pick of an older pair is a wrong write nobody catches by its hash. No build in WORK: the
    remembered pair, when both files are there with one record beside them. Two newest builds from the same moment
    ask. A .dfu with no record beside it (a rewrite file, a read) is never a candidate. Finding judges nothing."""
    remembered = None
    if upper and owner and os.path.isfile(upper) and os.path.isfile(owner):
        found = find_record(upper, owner)
        if found[0] == "one":
            remembered = (upper, owner, found[1])
    builds = {}
    for name in sorted(os.listdir(work)) if os.path.isdir(work) else []:
        path = os.path.join(work, name)
        if not name.endswith(".dfu") or not os.path.isfile(build_record.carried(path)):
            continue
        try:
            address = dfupatch.parse(dfupatch.read(path)).address
            with open(build_record.carried(path), "rb") as f:
                record = f.read()
        except (dfupatch.Refused, OSError, ValueError):
            continue
        side = "upper" if address == build_upper_dfu.UPPER_BASE else "owner" if address == drawn_flash.APP_BASE else None
        if side:
            builds.setdefault(record, {}).setdefault(side, []).append(path)
    pairs = [(built_at(build_record.carried(b["upper"][0])), b["upper"][0], b["owner"][0])
             for b in builds.values() if len(b.get("upper", [])) == 1 and len(b.get("owner", [])) == 1]
    pairs.sort(key=lambda p: p[0] or 0, reverse=True)
    if pairs:
        if len(pairs) > 1 and pairs[0][0] == pairs[1][0]:
            return ("ask", f"Two builds of block B and the owner's image in {work} are from the same moment; name them "
                           f"with --upper and --owner.")
        _, new_upper, new_owner = pairs[0]
        record = build_record.carried(new_upper)
        last = ""
        if remembered and dfupatch.read(remembered[2]) != dfupatch.read(record):
            last = remembered[2]
        return ("one", new_upper, new_owner, record, last)
    if remembered:
        return ("one", *remembered, "")
    return ("ask", f"No build of block B and the owner's image with its record beside it in {work}.")


# MARK: the plan

def out(plan, name):
    return os.path.join(plan["work"], f"{name}-{plan['run']}")


def next_action(path):
    plan = load(path)
    action = decide(plan)
    save(path, plan)   # the remembered file checks
    return action


def decide(plan):
    files = plan["files"]
    # Ready check: nothing sent.
    for label, image in (("the image the chip runs now", files["current"]), ("the owner's image", files["owner"])):
        if not image:
            continue   # found from the read, after update mode (#603)
        ok, why = checked(plan, "verify", dfupatch.verify, {"input": image})
        if not ok:
            return ("stop", f"{label} doesn't verify: {why}. Nothing was sent.")
    ok, why = checked(plan, "files", drawn_flash.files, {"upper": files["upper"], "owner": files["owner"]})
    if not ok:
        return ("stop", f"Those aren't block B and the owner's image in their places: {why}. Nothing was sent.")
    # How A and B were built: `make arm`'s record, judged against the very bytes; never asked (#593).
    ok, why = checked(plan, "record", build_record.check,
                      {"record": files["record"], "owner": files["owner"], "upper": files["upper"]})
    if not ok:
        return ("stop", f"The build record refuses: {why}. Nothing was sent.")
    # The apps that open the unit are watched by the shell before the plan begins (#603); nothing else is asked.
    # Update mode, and the one device.
    entered = fact(plan, "update_mode")
    if entered is None:
        return ("update-mode",)
    if entered != "ok":
        return ("stop", "The display chip didn't come up in update mode.")
    dfu_path, problem = one_display_chip(plan, "list")
    if problem:
        return problem
    # Before (read-only): the app, the option bytes, the upper flash.
    if unreadable(plan, "app_read"):
        return unreadable(plan, "app_read")
    if not fresh(plan, "app_read"):
        return ("read", "app", dfu_path, out(plan, "wd-app-before"), "app_read")
    current, finishing = files["current"], False
    if not current:
        current = found_current(plan)
        if current is not None:
            forget_app_write(plan, earlier_only=True)   # a known image was there: an earlier run's record is stale
        elif fact(plan, "interrupted_found") is not None:
            finishing = True   # this run took the record up; it's forgotten once the write is verified
        else:
            finishing, problem = interrupted(plan)
            if problem:
                return problem
            if not finishing:
                return ("stop", f"The app area matches none of the images the wizard knows: the owner's image, the one "
                                f"from the last run, or a .dfu in {plan['work']}. That file is the way back, so it must "
                                f"be known. Run again with --current PATH. Nothing was written.")
        if current and fact(plan, "current_found") is None:
            return ("skip", "current_found", f"The chip runs {current} now: the read matches it byte for byte. It's "
                                             f"the way back.")
        if finishing and fact(plan, "interrupted_found") is None:
            return ("skip", "interrupted_found", f"The app area holds a write of {files['owner']} that this wizard "
                                                 f"started and didn't verify. That same write is offered again.")
    if current:
        ok, why = checked(plan, "compare", dfupatch.compare, {"input": current, "readback": fact(plan, "app_read")})
        if not ok:
            return ("stop", f"The chip doesn't hold the image it runs now ({why}). Nothing was written.")
    ok, app_state = checked(plan, "app", drawn_flash.app, {"owner": files["owner"], "read": fact(plan, "app_read")})
    if not ok:
        return ("stop", f"The app area couldn't be judged against the owner's image: {app_state}")
    if unreadable(plan, "options_read"):
        return unreadable(plan, "options_read")
    if not fresh(plan, "options_read"):
        return ("read", "options", dfu_path, out(plan, "wd-option-bytes"), "options_read")
    ok, why = checked(plan, "options", drawn_flash.options, {"read": fact(plan, "options_read")})
    if not ok:
        return ("stop", f"The chip's protection isn't what block B needs: {why}. Nothing was written.")
    if unreadable(plan, "upper_read"):
        return unreadable(plan, "upper_read")
    if not fresh(plan, "upper_read"):
        return ("read", "upper", dfu_path, out(plan, "wd-upper-before"), "upper_read")
    ok, upper_state = checked(plan, "upper", drawn_flash.upper, {"upper": files["upper"], "read": fact(plan, "upper_read")})
    if not ok:
        return ("stop", f"The flash above the image is neither erased, this block B, nor a block B that checks out: "
                        f"{upper_state}. Nothing is written over it.")
    # The probe, up front whenever the owner's image is to be written (#603): a "no" without NO PROBE stops before
    # anything is written, never half way.
    if not app_state.startswith("holds"):
        _, problem = probe(plan)
        if problem:
            return problem
    # Step 1: block B.
    step = step_upper(plan, dfu_path, upper_state)
    if step:
        return step
    # Step 2: the owner's image.
    there = f"{current} (the way back)" if current else f"an interrupted write of {files['owner']}"
    step = step_app(plan, dfu_path, app_state, there, finishing)
    if step:
        return step
    # Power cycle.
    cycled = fact(plan, "power_cycle")
    if cycled is None:
        return ("power-cycle",)
    if cycled != "ok":
        return ("stop", "The display's MIDI port didn't come back after the power cycle.")
    # The stock look is the owner's to see, printed by the shell; nothing is written after it (#603).
    return ("done",)


def found_current(plan):
    """The first candidate that verifies as a wd image and matches this run's app read byte for byte: the owner's
    image, the remembered file, then each .dfu in the work folder by name. None when none does."""
    files, work = plan["files"], plan["work"]
    candidates = [files["owner"], files.get("remembered", "")]
    candidates += [os.path.join(work, n) for n in sorted(os.listdir(work)) if n.endswith(".dfu")]
    seen = set()
    for path in candidates:
        if not path or os.path.realpath(path) in seen or not os.path.isfile(path):
            continue
        seen.add(os.path.realpath(path))
        if checked(plan, "verify", dfupatch.verify, {"input": path})[0] and \
                checked(plan, "compare", dfupatch.compare, {"input": path, "readback": fact(plan, "app_read")})[0]:
            return path
    return None


WHAT = {"app_read": "the app area", "options_read": "the option bytes", "upper_read": "the flash above the image",
        "upper_back": "block B's read-back", "app_back": "the owner's image's read-back"}


def unreadable(plan, key):
    """A stop when this run's read of `key` failed (dfu-util refused it), so it's never just asked for again."""
    if fact(plan, key) != "failed":
        return None
    return ("stop", f"{WHAT[key][0].upper()}{WHAT[key][1:]} couldn't be read, so it can't be checked. Nothing more is "
                    f"written.")


def judge_devices(listing):
    """What dfu-util -l saw (#567): ("one", path) for exactly one device that is the display chip; else ("stop", why):
    none, two, the top panel chip, or a layout that isn't the display chip's, which is refused, never asked (#603).
    Both wizards' look uses it."""
    found = devices(listing)
    if len(found) != 1:
        return ("stop", f"{len(found)} update-mode devices found; exactly one, the display chip, is needed. Two "
                        f"means the top panel chip is in update mode too.")
    (dfu_path, names), = found.items()
    if any(TOP_PANEL_LAYOUT in name for name in names):
        return ("stop", "That's the top panel chip (256 KB), not the display chip. It's in update mode from "
                        "BACK + FWD + VINYL: power the LC6000 off and on to leave it. Nothing was read or written.")
    if not any(DISPLAY_LAYOUT in name for name in names):
        return ("stop", "Its memory layout isn't the display chip's 1 MB one, so it isn't the display chip. Nothing "
                        "was read or written.")
    return ("one", dfu_path)


def one_display_chip(plan, key):
    """(the DFU path, None), or (None, an action): exactly one device, and it's the display chip."""
    listing = fact(plan, key)
    if listing is None:
        return None, ("list", out(plan, f"dfu-{key}"), key)
    judged_devices = judge_devices(listing)
    if judged_devices[0] == "stop":
        return None, judged_devices
    return judged_devices[1], None


def step_upper(plan, dfu_path, upper_state):
    files = plan["files"]
    if upper_state.startswith("holds"):
        if fact(plan, "upper_step") is None:
            return ("skip", "upper_step", "Block B is already there, exactly. Step 1 has nothing to write.")
        return None
    rewrite = upper_state.startswith("replace")
    word = "REWRITE" if rewrite else "FLASH"
    written = fact(plan, "upper_written")
    if written is None:
        # The file that is written, made before its word, so the screen shows exactly it (#603).
        image = files["upper"]
        if rewrite:
            image = out(plan, "wd-upper-rewrite") + ".dfu"
            if not os.path.exists(image):
                ok, why = judged(drawn_flash.rewrite, upper=files["upper"], read=fact(plan, "upper_read"), output=image)
                if not ok:
                    return ("stop", f"The rewrite file couldn't be made: {why}. Nothing was written.")
        typed = fact(plan, "word_upper")
        if typed is None:
            end = build_upper_dfu.UPPER_BASE + len(dfupatch.parse(dfupatch.read(image)).element) - 1
            return ("type", "word_upper", word, screen(
                f"This ERASES and WRITES the display chip's upper flash, 0x08080000-0x{end:08X}, with block B.",
                image, f"there now: {there_now(upper_state)}", word, *build_lines(files)))
        if typed.strip() != word:
            return ("stop", f"You typed {typed.strip()!r}, not {word}. Nothing was written.")
        return ("write", "upper", dfu_path, image, "upper_written")
    if written != "0":
        return ("stop", "dfu-util reported an error writing block B. Don't retry blindly. Until the owner's image is "
                        "on, the image there now runs as before: a part of B is never called.")
    if fact(plan, "upper_back") is None:
        return ("read", "upper", dfu_path, out(plan, "wd-upper-after"), "upper_back")
    if unreadable(plan, "upper_back"):
        return unreadable(plan, "upper_back")
    ok, state = checked(plan, "upper", drawn_flash.upper, {"upper": files["upper"], "read": fact(plan, "upper_back")})
    if not ok or not state.startswith("holds"):
        return ("stop", "The upper flash isn't exactly block B after the write. Block A checks B's CRC before calling "
                        "it, so it stays unused. Don't flash the owner's image on top: post this on #468.")
    return None


PROBE_FILE = "probe.json"


def listing_serial(listing):
    """The display chip's DFU serial from dfu-util -l: the ST bootloader's, from the chip's own ID. None if absent."""
    import re
    for line in open(listing):
        if "[0483:df11]" in line.lower():
            found = re.search(r'serial="([^"]*)"', line)
            if found:
                return found.group(1)
    return None


def probe(plan):
    """(the word screen's probe line, None), or (None, an action) (#603). Asked only when the owner's image is to be
    written, before the first write; a B-only rewrite leaves the app area, and the update-mode path in it, as they are. The answer (yes, or
    no with NO PROBE typed) is remembered in the work folder for today and this unit's DFU serial; another day,
    another unit or an unreadable file asks again. `flash-day.sh drawn --probe-again` forgets it."""
    import time
    path = os.path.join(plan["work"], PROBE_FILE)
    serial, today = listing_serial(fact(plan, "list")), time.strftime("%Y-%m-%d")
    try:
        with open(path) as f:
            kept = json.load(f)
        if kept["date"] == today and kept["serial"] == serial and serial and kept["answer"] in ("yes", "no probe"):
            if kept["answer"] == "yes":
                return f"▶ probe: yes (answered today at {kept['time']})", None
            return f"▶ probe: NO, {drawn_flash.NO_PROBE} typed today at {kept['time']}: no way back over USB if the " \
                   f"image can't take the update-mode message", None
    except (OSError, ValueError, KeyError, TypeError):
        pass
    answer = fact(plan, "probe")
    if answer is None:
        return None, ("ask", "probe", "Is an ST-Link probe connected, and can it read the chip (#433)?")
    if answer != "y":
        typed = fact(plan, "no_probe")
        if typed is None:
            return None, ("type", "no_probe", drawn_flash.NO_PROBE, drawn_flash.NO_PROBE_RISK)
        if typed.strip() != drawn_flash.NO_PROBE:
            return None, ("stop", f"You typed {typed.strip()!r}, not {drawn_flash.NO_PROBE}. Nothing was written.")
    kept = {"date": today, "time": time.strftime("%H:%M"), "serial": serial, "answer": "yes" if answer == "y" else "no probe"}
    if serial:
        with open(path, "w") as f:
            json.dump(kept, f)
        return probe(plan)
    return f"▶ probe: {'yes' if answer == 'y' else 'NO, ' + drawn_flash.NO_PROBE} (answered just now; no serial to " \
           f"remember it by)", None


def build_lines(files):
    """Which build is written (#603): the record's commit and build time, and last run's commit when it differs."""
    import time

    def read(path):
        try:
            with open(path) as f:
                record = json.load(f)
            return record if isinstance(record, dict) else {}
        except (OSError, ValueError):
            return {}
    this = read(files["record"])
    if isinstance(this.get("commit"), str) and isinstance(this.get("built"), (int, float)):
        lines = [f"▶ build: {this['commit']}, built {time.strftime('%Y-%m-%d %H:%M', time.localtime(this['built']))}"]
    else:
        lines = ["▶ build: commit unknown (a record from before #603)"]
    last = read(files.get("last_record") or "")
    if last:
        lines.append(f"▶ last run used: {last.get('commit', 'commit unknown')}")
    return lines


def there_now(upper_state):
    """drawn_flash's state line as the screen says it: "erased (nothing there yet)", or what's to be replaced."""
    if not upper_state.startswith("replace"):
        return upper_state
    return upper_state[upper_state.index("(") + 1:].split(";")[0].rstrip(")")


def screen(what, image, there, word, *more):
    """A write's word screen (#603): what's written where, the file and its sha256 (the shell shows ▶ lines bold),
    what's there now, then the checks only the owner can make."""
    import hashlib
    with open(image, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    return "\n".join((what, f"▶ file: {image}", f"▶ sha256: {digest}", f"  {there}", *more,
                      "  Check: the LC6000 is on a direct cable (not a hub), and there's no gig today.",
                      f"Type {word} to write it."))


APP_WRITE_FILE = "app-write.json"


def sha256_of(path):
    import hashlib
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def remember_app_write(plan, image):
    """The wizard's own record of a write of the owner's image it starts (#603): the file, its sha256, B and the
    build record that went with it, and the unit's DFU serial. Forgotten once the read-back matches."""
    import time
    with open(os.path.join(plan["work"], APP_WRITE_FILE), "w") as f:
        json.dump({"file": os.path.realpath(image), "sha256": sha256_of(image), "upper": plan["files"]["upper"],
                   "record": plan["files"]["record"], "serial": listing_serial(fact(plan, "list")),
                   "started": time.strftime("%Y-%m-%d %H:%M"), "run": plan["run"]}, f)


def forget_app_write(plan, earlier_only=False):
    """EARLIER_ONLY: only a record from another run; this run's own write keeps its record until verified."""
    path = os.path.join(plan["work"], APP_WRITE_FILE)
    if earlier_only:
        try:
            with open(path) as f:
                if json.load(f).get("run") == plan["run"]:
                    return
        except (OSError, ValueError, AttributeError):
            pass
    with contextlib.suppress(FileNotFoundError):
        os.remove(path)


def interrupted(plan):
    """(True, None) when the wizard's record says it started writing exactly this run's owner's image (the same file
    and sha256) on this unit and never verified it: the one way past an app area that matches no file. (False, None)
    with no record; (False, a stop) when the record is for another file, another hash or another unit."""
    try:
        with open(os.path.join(plan["work"], APP_WRITE_FILE)) as f:
            kept = json.load(f)
        image, digest, serial = kept["file"], kept["sha256"], kept["serial"]
    except FileNotFoundError:
        return False, None
    except (OSError, ValueError, KeyError, TypeError):
        return False, ("stop", "The record of an interrupted write can't be read, so the app area matches nothing known. "
                               "Run again with --current PATH. Nothing was written.")
    owner = plan["files"]["owner"]
    if os.path.realpath(owner) == image and sha256_of(owner) == digest and serial and \
            serial == listing_serial(fact(plan, "list")):
        return True, None
    return False, ("stop", f"The app area matches no known image, and the interrupted write this wizard started "
                           f"({kept.get('started', '?')}) was of {image}, sha256 {digest[:12]}…, which isn't this run's "
                           f"owner's image as it is now, or was on another unit. To finish that write, run again with "
                           f"--upper {kept.get('upper', '?')} --owner {image}, the file unchanged. Nothing was written.")


def step_app(plan, dfu_path, app_state, there, finishing=False):
    files = plan["files"]
    if app_state.startswith("holds"):
        if fact(plan, "app_step") is None:
            return ("skip", "app_step", "The owner's image is already there, exactly. Nothing to write: the app "
                                        "area isn't touched.")
        return None
    written = fact(plan, "app_written")
    if written is None:
        again, problem = one_display_chip(plan, "list_again")
        if problem:
            return problem
        if again != dfu_path:
            return ("stop", "The display chip isn't at the same USB path any more.")
        probe_line, problem = probe(plan)
        if problem:
            return problem
        typed = fact(plan, "word_app")
        if typed is None:
            return ("type", "word_app", "FLASH", screen(
                ("FINISHING AN INTERRUPTED WRITE: the same file and hash as the write that was cut off. " if finishing
                 else "") +
                "This ERASES and WRITES the display chip's app area, 0x08008000-0x0807FFFF, with the owner's image.",
                files["owner"], f"there now: {there}", "FLASH", *build_lines(files), probe_line))
        if typed.strip() != "FLASH":
            return ("stop", f"You typed {typed.strip()!r}, not FLASH. Nothing was written.")
        remember_app_write(plan, files["owner"])
        return ("write", "app", dfu_path, files["owner"], "app_written")
    if written != "0":
        return ("stop", "dfu-util reported an error writing the owner's image. Don't power-cycle: the chip is still "
                        "in update mode, so Denon's updater or the slot 16 image can go on now.")
    if fact(plan, "app_back") is None:
        return ("read", "app", dfu_path, out(plan, "wd-app-after"), "app_back")
    if unreadable(plan, "app_back"):
        return unreadable(plan, "app_back")
    ok, why = checked(plan, "compare", dfupatch.compare, {"input": files["owner"], "readback": fact(plan, "app_back")})
    if not ok:
        return ("stop", f"What's on the chip differs from the owner's image ({why}). Don't power-cycle into it: "
                        f"run the wizard again to write it once more, or flash the stock or slot 16 image.")
    forget_app_write(plan)   # verified (#603)
    return None


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    command = argv[0] if argv else ""
    if command == "begin" and len(argv) in (7, 8, 9):
        begin(argv[1], current=argv[2], upper=argv[3], owner=argv[4], record=argv[5], work=argv[6],
              remembered=argv[7] if len(argv) >= 8 else "", last_record=argv[8] if len(argv) == 9 else "")
    elif command == "next" and len(argv) == 2:
        # One line, fields separated by tabs; a field's own line breaks as \\n (the shell prints them with %b).
        print("\t".join(field.replace("\\", "\\\\").replace("\n", "\\n") for field in next_action(argv[1])))
    elif command == "devices" and len(argv) == 2:
        print("\t".join(judge_devices(argv[1])))
    elif command == "find-files" and len(argv) == 4:
        print("\t".join(find_files(argv[1], argv[2], argv[3])))
    elif command == "find-record" and len(argv) == 3:
        print("\t".join(find_record(argv[1], argv[2])))
    elif command == "record" and len(argv) == 4:
        record(argv[1], argv[2], argv[3])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
