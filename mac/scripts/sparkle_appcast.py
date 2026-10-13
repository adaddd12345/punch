#!/usr/bin/env python3
"""Signs an update archive with Sparkle's EdDSA (Ed25519) scheme and writes a
appcast.xml with the new item first, followed by the newest few items of the
previous feed (--previous), so the previous build is never dropped.

Usage:
  SPARKLE_ED_PRIVATE_KEY=<base64 32-byte seed> \\
  sparkle_appcast.py ZIP --version BUILD --short VERSION --url URL \\
                     [--notes-url URL] [--notes TEXT] [--min-os 14.4] \\
                     [--previous old-appcast.xml] [--keep 4] -o appcast.xml

The private key format matches Sparkle's `generate_keys -x` export (base64
seed); the public half lives in Info.plist as SUPublicEDKey. Sparkle verifies
the signature over the raw archive bytes.
"""
import argparse
import base64
import email.utils
import html
import os
import re
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("zip")
    ap.add_argument("--version", required=True, help="CFBundleVersion (monotonic integer)")
    ap.add_argument("--short", required=True, help="CFBundleShortVersionString")
    ap.add_argument("--url", required=True, help="public download URL of the archive")
    ap.add_argument("--notes-url", default="")
    ap.add_argument("--notes", default="")
    ap.add_argument("--min-os", default="14.4")
    ap.add_argument("--expect-public-key", default="", help="fail if the key doesn't match this SUPublicEDKey")
    ap.add_argument("--previous", default="", help="existing appcast.xml whose newest items are kept")
    ap.add_argument("--keep", type=int, default=4, help="how many previous items to keep")
    ap.add_argument("-o", "--output", required=True)
    a = ap.parse_args()

    raw = os.environ.get("SPARKLE_ED_PRIVATE_KEY", "").strip()
    if not raw:
        print("SPARKLE_ED_PRIVATE_KEY is not set", file=sys.stderr)
        return 2
    key_bytes = base64.b64decode(raw)
    if len(key_bytes) == 64:  # tolerate seed+public concatenations
        key_bytes = key_bytes[:32]
    key = Ed25519PrivateKey.from_private_bytes(key_bytes)
    pub = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw,
                                                         serialization.PublicFormat.Raw)).decode()
    if a.expect_public_key and pub != a.expect_public_key:
        print(f"private key does not match SUPublicEDKey ({pub} != {a.expect_public_key})", file=sys.stderr)
        return 3

    data = open(a.zip, "rb").read()
    sig = base64.b64encode(key.sign(data)).decode()
    key.public_key().verify(base64.b64decode(sig), data)  # self-check

    notes = ""
    if a.notes_url:
        notes += f"      <sparkle:releaseNotesLink>{html.escape(a.notes_url)}</sparkle:releaseNotesLink>\n"
    elif a.notes:
        notes += f"      <description><![CDATA[<p>{html.escape(a.notes)}</p>]]></description>\n"

    # Keep the newest few items of the previous feed after the new one, so the
    # previous build stays listed (a fallback if the new one is bad).
    previous = ""
    if a.previous and os.path.exists(a.previous):
        old = open(a.previous, encoding="utf-8", errors="replace").read()
        kept = []
        for item in re.findall(r"[ \t]*<item>.*?</item>", old, re.S):
            m = re.search(r"<sparkle:version>([^<]*)</sparkle:version>", item)
            if not m or m.group(1).strip() == a.version:
                continue
            kept.append(item.strip("\n"))
            if len(kept) >= a.keep:
                break
        previous = "".join("\n" + k for k in kept)

    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>The Bass Shaker</title>
    <item>
      <title>The Bass Shaker {html.escape(a.short)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(a.version)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(a.short)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(a.min_os)}</sparkle:minimumSystemVersion>
{notes}      <enclosure url="{html.escape(a.url)}" length="{len(data)}" type="application/octet-stream"
                 sparkle:edSignature="{sig}"/>
    </item>{previous}
  </channel>
</rss>
"""
    open(a.output, "w").write(xml)
    print(f"appcast: build {a.version} ({a.short}), {len(data)} bytes, key {pub}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
