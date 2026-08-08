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
# Known unfixable high-severity CVEs as of 2026-08-04.
# Review these whenever Docusaurus or serialize-javascript is updated.
# -----------------------------------------------------------------------
KNOWN_UNFIXED_HIGHS=(
  "GHSA-5c6j-r48x-rmvq" # serialize-javascript RCE via RegExp.flags (build-time only, fixedIn: null)
  "GHSA-qj8w-gfj5-8c6v" # serialize-javascript DoS via array-like objects (build-time only, fixedIn: null)
  "GHSA-w5hq-g745-h8pq" # uuid missing buffer bounds check in v3/v5/v6 (build-time only, only fix requires breaking Docusaurus downgrade)
  "GHSA-v2hh-gcrm-f6hx" # fast-uri build-time host confusion; 3.1.5 is not available from the configured registry
  "GHSA-7p8r-x3mc-p8w7" # fast-uri build-time host confusion; 3.1.5 is not available from the configured registry
)

UNAVAILABLE_FIX_SPECS=(
  "fast-uri@3.1.5"
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

  for spec in "${UNAVAILABLE_FIX_SPECS[@]}"; do
    if npm view "${spec}" version --json >/dev/null 2>&1; then
      die "npm audit: ${spec} is now available; remove its exception and update the lockfile"
    fi
  done

  printf '[audit] All highs are in the reviewed exception list; advertised patch packages remain unavailable. Passing with warning.\n\n'
fi

printf '[audit] npm security gate passed.\n'
