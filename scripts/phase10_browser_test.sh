#!/usr/bin/env bash
set -euo pipefail
PYTHON=''
if python3 -c 'import playwright' >/dev/null 2>&1; then PYTHON=python3
elif [[ -x /opt/pyvenv/bin/python ]] && /opt/pyvenv/bin/python -c 'import playwright' >/dev/null 2>&1; then PYTHON=/opt/pyvenv/bin/python
else echo 'Playwright Python runtime is required for Phase 10 browser proofs' >&2; exit 2; fi
if [[ -n "${PHASE10_CHROMIUM_PATH:-}" ]]; then :
elif command -v chromium >/dev/null 2>&1; then export PHASE10_CHROMIUM_PATH="$(command -v chromium)"
elif [[ -x /usr/bin/chromium ]]; then export PHASE10_CHROMIUM_PATH=/usr/bin/chromium
else echo 'Chromium is required for Phase 10 browser proofs' >&2; exit 2; fi
"$PYTHON" scripts/phase10_browser_outbox_runtime.py
"$PYTHON" scripts/phase10_browser_duplicate_bin.py
