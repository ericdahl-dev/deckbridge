# The website deploys from main through Coolify

2026-11-16. getdeckbridge.app is plain HTML and CSS in `website/`, with no build step, checked by `scripts/check_site.py` (#169, #170). Coolify builds `main` and watches `website/`, so merging a site PR deploys it (#266); a site change that must wait, such as a release's copy, is held as an unmerged PR (#300).
