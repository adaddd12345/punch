#!/usr/bin/env python3
"""Signs an update archive with Sparkle's EdDSA (Ed25519) scheme and writes a
single-item appcast.xml.

Usage:
  SPARKLE_ED_PRIVATE_KEY=<base64 32-byte seed> \\
  sparkle_appcast.py ZIP --version BUILD --short VERSION --url URL \\
                     [--notes-url URL] [--notes TEXT] [--min-os 14.4] -o appcast.xml

The private key format matches Sparkle's `generate_keys -x` export (base64
seed); the public half lives in Info.plist as SUPublicEDKey. Sparkle verifies
the signature over the raw archive bytes.
"""
import argparse
import base64
import email.utils
import html
import os
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

    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Bass Shake</title>
    <item>
      <title>Bass Shake {html.escape(a.short)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(a.version)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(a.short)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(a.min_os)}</sparkle:minimumSystemVersion>
{notes}      <enclosure url="{html.escape(a.url)}" length="{len(data)}" type="application/octet-stream"
                 sparkle:edSignature="{sig}"/>
    </item>
  </channel>
</rss>
"""
    open(a.output, "w").write(xml)
    print(f"appcast: build {a.version} ({a.short}), {len(data)} bytes, key {pub}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
