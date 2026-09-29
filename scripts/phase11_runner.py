#!/usr/bin/env python3
"""Compatibility wrapper for the canonical fail-closed Phase 11 runner.

This wrapper never creates evidence itself. It delegates to phase11_runner.sh so
there is exactly one raw-evidence generation path.
"""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
subprocess.run(["bash", str(ROOT / "scripts" / "phase11_runner.sh")], cwd=ROOT, check=True)
