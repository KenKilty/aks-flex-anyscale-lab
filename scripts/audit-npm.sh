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
# Known unfixable high-severity CVEs as of 2026-07-02.
# Review these whenever Docusaurus or serialize-javascript is updated.
# -----------------------------------------------------------------------
KNOWN_UNFIXED_HIGHS=(
  "GHSA-5c6j-r48x-rmvq" # serialize-javascript RCE via RegExp.flags (build-time only, fixedIn: null)
  "GHSA-qj8w-gfj5-8c6v" # serialize-javascript DoS via array-like objects (build-time only, fixedIn: null)
  "GHSA-w5hq-g745-h8pq" # uuid missing buffer bounds check in v3/v5/v6 (build-time only, only fix requires breaking Docusaurus downgrade)
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

HIGH_FIXABLE="$(printf '%s' "${AUDIT_JSON}" |
  jq -r '
      .vulnerabilities
      | to_entries[]
      | select(
          (.value.severity == "high" or .value.severity == "critical")
          and (.value.fixAvailable == true)
        )
      | .key
  ' 2>/dev/null || true)"

HIGH_UNFIXABLE="$(printf '%s' "${AUDIT_JSON}" |
  jq -r '
      .vulnerabilities
      | to_entries[]
      | select(
          (.value.severity == "high" or .value.severity == "critical")
          and (.value.fixAvailable != true)
        )
      | .key
  ' 2>/dev/null || true)"

# ── Step 3: fail on fixable highs ───────────────────────────────────────
if [[ -n "${HIGH_FIXABLE}" ]]; then
  printf '\n[audit] HIGH vulnerabilities with available fixes:\n%s\n\n' "${HIGH_FIXABLE}"
  printf 'Run: npm audit fix\n'
  die "npm audit: fixable high-severity vulnerabilities block commit"
fi

# ── Step 4: warn on unfixable highs and check against exception list ────
if [[ -n "${HIGH_UNFIXABLE}" ]]; then
  printf '\n[audit] WARNING: high-severity vulnerabilities with no upstream fix:\n'
  while IFS= read -r pkg; do
    printf '  - %s\n' "${pkg}"
  done <<<"${HIGH_UNFIXABLE}"

  # Extract advisory IDs from the audit payload for comparison.
  ADVISORY_IDS="$(printf '%s' "${AUDIT_JSON}" |
    jq -r '.vulnerabilities[].via[] | if type == "object" then .url else empty end | split("/") | last' \
      2>/dev/null | sort -u || true)"

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
    printf 'Add them to KNOWN_UNFIXED_HIGHS in scripts/audit-npm.sh after review.\n'
    die "npm audit: unreviewed high-severity advisories block commit"
  fi

  printf '[audit] All unfixable highs are in the reviewed exception list. Passing with warning.\n\n'
fi

printf '[audit] npm security gate passed.\n'
