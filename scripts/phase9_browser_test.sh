#!/usr/bin/env bash
set -euo pipefail
PYTHON=''
if python3 -c 'import playwright' >/dev/null 2>&1; then
  PYTHON=python3
elif [[ -x /opt/pyvenv/bin/python ]] && /opt/pyvenv/bin/python -c 'import playwright' >/dev/null 2>&1; then
  PYTHON=/opt/pyvenv/bin/python
else
  echo 'Playwright Python runtime is required for Phase 9 browser proofs' >&2
  exit 2
fi
if ! command -v chromium >/dev/null 2>&1 && [[ ! -x /usr/bin/chromium ]]; then
  echo 'Chromium is required for Phase 9 browser proofs' >&2
  exit 2
fi
exec "$PYTHON" scripts/phase9_browser_runtime.py
