#!/usr/bin/env python3
"""Deterministically splice a release <item> into appcast.xml.

Used by .github/workflows/release.yml after scripts/release.sh has produced
dist/appcast-fragment.txt. Reads the release fields from environment
variables (set by the workflow from that fragment) and inserts a new <item>
as the first child of <channel> in appcast.xml at the repo root. If an item
for the same version already exists (e.g. a tag was re-pushed), it is
replaced rather than duplicated.

Required environment variables:
  VERSION        e.g. "0.2.0"
  BUILD_NUMBER   sparkle:version (monotonic integer, e.g. git commit count)
  DOWNLOAD_URL   full GitHub Release asset URL for the .zip
  LENGTH         byte length of the .zip, as printed by sign_update
  ED_SIGNATURE   sparkle:edSignature, as printed by sign_update
  PUB_DATE       RFC 2822 date string for <pubDate>
"""
import os
import re

REQUIRED_VARS = [
    "VERSION",
    "BUILD_NUMBER",
    "DOWNLOAD_URL",
    "LENGTH",
    "ED_SIGNATURE",
    "PUB_DATE",
]

# appcast.xml intentionally documents its own format with example <item>
# snippets inside XML comments (see the header comment and the in-channel
# template). A naive text search for "<item>" would match those examples
# too, so every lookup below is comment-aware: it locates all <!-- ... -->
# spans first and ignores any match that falls inside one.


def _comment_spans(content: str) -> list[tuple[int, int]]:
    return [(m.start(), m.end()) for m in re.finditer(r"<!--.*?-->", content, re.DOTALL)]


def _in_comment(pos: int, spans: list[tuple[int, int]]) -> bool:
    return any(start <= pos < end for start, end in spans)


def _remove_existing_item(content: str, version: str) -> str:
    """Drop a real (non-commented) <item> for `version`, if present."""
    spans = _comment_spans(content)
    pattern = re.compile(
        r"[ \t]*<item>\s*<title>" + re.escape(version) + r"</title>.*?</item>\s*\n",
        re.DOTALL,
    )
    for m in pattern.finditer(content):
        if not _in_comment(m.start(), spans):
            return content[: m.start()] + content[m.end() :]
    return content


def _insert_item(content: str, item: str) -> str:
    """Insert `item` before the first real <item>, else before </channel>."""
    spans = _comment_spans(content)

    for m in re.finditer(r"[ \t]*<item>", content):
        if not _in_comment(m.start(), spans):
            return content[: m.start()] + item + content[m.start() :]

    for m in re.finditer(r"\s*</channel>", content):
        if not _in_comment(m.start(), spans):
            return content[: m.start()] + "\n" + item + content[m.start() :]

    raise SystemExit("error: could not find an insertion point in appcast.xml")


def main() -> None:
    missing = [name for name in REQUIRED_VARS if not os.environ.get(name)]
    if missing:
        raise SystemExit(f"error: missing required env var(s): {', '.join(missing)}")

    version = os.environ["VERSION"]

    item = """    <item>
      <title>{version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{build_number}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure
        url="{download_url}"
        length="{length}"
        type="application/octet-stream"
        sparkle:edSignature="{ed_signature}" />
    </item>
""".format(
        version=version,
        pub_date=os.environ["PUB_DATE"],
        build_number=os.environ["BUILD_NUMBER"],
        download_url=os.environ["DOWNLOAD_URL"],
        length=os.environ["LENGTH"],
        ed_signature=os.environ["ED_SIGNATURE"],
    )

    path = "appcast.xml"
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    content = _remove_existing_item(content, version)
    content = _insert_item(content, item)

    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"Inserted appcast item for version {version}")


if __name__ == "__main__":
    main()
