#!/usr/bin/env bash
# Start the Docusaurus dev server with a fresh cache.
# Kills any process already on port 3000, runs docusaurus clear,
# then starts the dev server — matching the Docusaurus-recommended
# practice of clearing before restarting when content changes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

DOCS_PORT="${DOCS_PORT:-3000}"

# Kill anything on the port so npm start doesn't prompt
if lsof -ti:"${DOCS_PORT}" >/dev/null 2>&1; then
  printf 'Stopping existing server on port %s...\n' "${DOCS_PORT}"
  lsof -ti:"${DOCS_PORT}" | xargs kill -9 2>/dev/null || true
  sleep 1
fi

npm run dev
