# PlatformIO pre-build script (#615): puts the repo's short commit in the build, on the test screen and serial, so
# whoever looks at the panel can tell which build is on it. "-dirty" when tools/deck-panel has uncommitted changes;
# "unknown" outside git. Also the firmware's version (#695), from VERSION: a release only when HEAD carries the tag
# deck-panel-v<version> and tools/deck-panel is clean; any other build is local.
import pathlib
import re
import subprocess


def short_sha(cwd):
    try:
        sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=cwd, capture_output=True, text=True,
                             check=True).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain", "--", "."], cwd=cwd, capture_output=True, text=True,
                               check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"
    return sha + ("-dirty" if dirty else "")


def build_version(cwd):
    """(version, release) for the build in `cwd`. A VERSION that isn't dotted digits stops the build."""
    version = (pathlib.Path(cwd) / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+(\.\d+)*", version):
        raise ValueError(f"VERSION {version!r} is not a dotted version such as 1.0.0")
    try:
        tags = subprocess.run(["git", "tag", "--points-at", "HEAD"], cwd=cwd, capture_output=True, text=True,
                              check=True).stdout.split()
        dirty = subprocess.run(["git", "status", "--porcelain", "--", "."], cwd=cwd, capture_output=True, text=True,
                               check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return version, False
    return version, f"deck-panel-v{version}" in tags and not dirty


if "Import" in globals():  # under PlatformIO's SCons; the tests import this file without it
    Import("env")  # noqa: F821 (PlatformIO's SCons global)
    project = env.subst("$PROJECT_DIR")  # noqa: F821
    version, release = build_version(project)
    env.Append(CPPDEFINES=[  # noqa: F821
        ("DECK_PANEL_SHA", '\\"%s\\"' % short_sha(project)),
        ("DECK_PANEL_VERSION", '\\"%s\\"' % version),
        ("DECK_PANEL_RELEASE", 1 if release else 0),
    ])
