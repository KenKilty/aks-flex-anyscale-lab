#!/usr/bin/env bash
# Run the full pre-commit hook suite against every file, without committing.
#
# This does exactly what the git pre-commit hooks defined in
# .pre-commit-config.yaml would do on commit, but on demand and across the
# whole tree. Pass an optional hook id to run a single hook, e.g.:
#
#   scripts/run-pre-commit.sh            # run all hooks on all files
#   scripts/run-pre-commit.sh mypy       # run only the mypy hook
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ ! -d .git ]]; then
  echo "error: not a git repository (run 'git init' first)." >&2
  exit 1
fi

# Some hooks rely on Go-installed tools (e.g. shfmt via 'go install').
# Make sure the Go bin directory is on PATH if Go is available.
if command -v go >/dev/null 2>&1; then
  GOBIN="$(go env GOPATH)/bin"
  case ":${PATH}:" in
  *":${GOBIN}:"*) ;;
  *) export PATH="${PATH}:${GOBIN}" ;;
  esac
fi

if ! command -v pre-commit >/dev/null 2>&1; then
  echo "error: 'pre-commit' is not installed." >&2
  echo "Install it with one of: 'pipx install pre-commit', 'brew install pre-commit', or 'pip install pre-commit'." >&2
  exit 1
fi

# pre-commit --all-files only inspects files tracked by git. Register any
# not-yet-tracked files with intent-to-add (respects .gitignore, so ignored
# secrets like .env* stay out) so the hooks see the whole tree. This does not
# create a commit and does not stage file contents.
git add --intent-to-add --all

exec pre-commit run --all-files "$@"
