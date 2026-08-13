#!/usr/bin/env bash
# Security audit gate for npm dependencies.
#
# Policy:
#   critical  – hard block. Fail immediately.
#   high      – warn. Print summary and exit non-zero ONLY when the findings are
#               fixable (i.e. a patch is available without breaking changes).
#               Unfixable transitive vulnerabilities in build-time tooling are
#               logged but do not block the gate.  They MUST be reviewed and
#               explicitly documented in KNOWN_UNFIXED_HIGHS below.
#
# To re-evaluate open exceptions, run:
#   npm audit --audit-level=high

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# -----------------------------------------------------------------------
# Known unfixable high-severity CVEs as of 2026-08-13.
# Review these whenever Docusaurus, serialize-javascript, or postcss is updated.
# -----------------------------------------------------------------------
KNOWN_UNFIXED_HIGHS=(
  "GHSA-5c6j-r48x-rmvq" # serialize-javascript RCE via RegExp.flags (build-time only, fixedIn: null)
  "GHSA-qj8w-gfj5-8c6v" # serialize-javascript DoS via array-like objects (build-time only, fixedIn: null)
  "GHSA-w3rx-r6r6-pgpr" # image-size ICNS parser DoS; build-time parser receives only trusted repository images, fixedIn: null
  "GHSA-5p2g-fcmc-qvqq" # image-size JXL/HEIF parser DoS; build-time parser receives only trusted repository images, fixedIn: null
  "GHSA-2v37-7h3g-55p8" # nanoid custom generators loop when size is 0; unreachable because postcss's only call is nanoid(6) at build time, and the named fix 3.3.18 is unpublished while postcss still requires ^3.3.17. Remove once a patched nanoid 3.x ships.
)

die() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

# ── Step 1: block on any critical vulnerability ─────────────────────────
if ! npm audit --audit-level=critical --json >/dev/null 2>&1; then
  printf '\n[audit] CRITICAL vulnerabilities found. Review and fix before committing.\n'
  npm audit --audit-level=critical
  die "npm audit: critical vulnerabilities block commit"
fi
printf '[audit] No critical vulnerabilities.\n'

# ── Step 2: collect high vulnerabilities ────────────────────────────────
AUDIT_JSON="$(npm audit --json 2>/dev/null || true)"

HIGH_PACKAGES="$(printf '%s' "${AUDIT_JSON}" |
  jq -r '
      .vulnerabilities
      | to_entries[]
      | select(
          .value.severity == "high" or .value.severity == "critical"
        )
      | .key
  ' 2>/dev/null || true)"

if [[ -n "${HIGH_PACKAGES}" ]]; then
  printf '\n[audit] WARNING: high-severity vulnerabilities in build tooling:\n'
  while IFS= read -r pkg; do
    printf '  - %s\n' "${pkg}"
  done <<<"${HIGH_PACKAGES}"

  ADVISORY_IDS="$(printf '%s' "${AUDIT_JSON}" |
    jq -r '
      .vulnerabilities
      | to_entries[]
      | select(.value.severity == "high" or .value.severity == "critical")
      | .value.via[]
      | if type == "object" then .url else empty end
      | split("/")
      | last
    ' \
      2>/dev/null | sort -u || true)"

  [[ -n "${ADVISORY_IDS}" ]] || die "npm audit: high-severity packages found without advisory IDs"

  UNLISTED_ADVISORIES=""
  while IFS= read -r advisory; do
    [[ -z "${advisory}" ]] && continue
    listed=0
    for known in "${KNOWN_UNFIXED_HIGHS[@]}"; do
      [[ "${advisory}" == "${known}" ]] && listed=1 && break
    done
    if [[ "${listed}" -eq 0 ]]; then
      UNLISTED_ADVISORIES="${UNLISTED_ADVISORIES}${advisory}"$'\n'
    fi
  done <<<"${ADVISORY_IDS}"

  if [[ -n "${UNLISTED_ADVISORIES}" ]]; then
    printf '\n[audit] NEW high/critical advisories not yet reviewed:\n%s\n' "${UNLISTED_ADVISORIES}"
    printf 'Add them to KNOWN_UNFIXED_HIGHS in scripts/audit-npm.sh only after review.\n'
    die "npm audit: unreviewed high-severity advisories block commit"
  fi

  printf '[audit] All highs are in the reviewed exception list. Passing with warning.\n\n'
fi

printf '[audit] npm security gate passed.\n'
