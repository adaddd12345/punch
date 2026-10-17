#!/usr/bin/env python3
"""Compatibility entry point for menu-bar generation from the approved SVG.

The old bitmap extraction from icon-source.webp is deliberately retired.
Usage: python3 mac/scripts/make_icons.py [--check] [--preview /tmp/proof.png]
"""
from pathlib import Path
import subprocess
import sys

script = Path(__file__).resolve().with_name("make_menubar_icon.sh")
raise SystemExit(subprocess.call(["bash", str(script), *sys.argv[1:]]))
