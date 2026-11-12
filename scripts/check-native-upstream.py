#!/usr/bin/env python3
"""Compatibility entry point: check every native dependency and build tool."""
from pathlib import Path
import subprocess
import sys
raise SystemExit(subprocess.call([sys.executable,str(Path(__file__).with_name('check-dependency-updates.py')),'--scope','native']+sys.argv[1:]))
