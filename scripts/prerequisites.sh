#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# prerequisites.sh — Validate required tools
# ---------------------------------------------------------------------------
# Every workflow step runs through containers, so the container engine is the
# only host prerequisite. Which engine (docker | podman) is chosen by
# container.engine in config.yaml.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${REPO_ROOT}/config.yaml"

# shellcheck source=scripts/container-runtime.sh
source "${SCRIPT_DIR}/container-runtime.sh"

ERRORS=0

# Container engine (docker | podman) — from container.engine in config.yaml.
ENGINE="$(container_engine_name "${CONFIG}")" || exit 1

if command -v "${ENGINE}" &>/dev/null; then
  ENGINE_VERSION="$("${ENGINE}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  printf 'OK  %-10s %s\n' "${ENGINE}" "${ENGINE_VERSION}"
else
  echo "MISSING  ${ENGINE}      (not found on PATH)" >&2
  ERRORS=$((ERRORS + 1))
fi

if [[ "${ERRORS}" -gt 0 ]]; then
  echo ""
  echo "ERROR: ${ERRORS} prerequisite check(s) failed. Resolve the issues above before continuing." >&2
  exit 1
fi

echo ""
echo "All prerequisites satisfied."
