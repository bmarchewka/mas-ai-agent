#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# prerequisites.sh — Validate required tools
# ---------------------------------------------------------------------------
# Every workflow step runs through containers, so the container engine is the
# main host prerequisite. Which engine (docker | podman) is chosen by
# container.engine in config.yaml. Reading/writing config.yaml (nested
# status.operators, version lists) additionally needs yq (mikefarah) or
# python3 — either one is enough. Step 2's catalog resolver prefers python3 and
# otherwise runs in a throwaway python container.
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

# config.yaml parser — yq (mikefarah) preferred, python3 as fallback.
if command -v yq &>/dev/null && yq --version 2>/dev/null | grep -q mikefarah; then
  YQ_VERSION="$(yq --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  printf 'OK  %-10s %s\n' "yq" "${YQ_VERSION}"
fi
if command -v python3 &>/dev/null; then
  PY_VERSION="$(python3 --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  printf 'OK  %-10s %s\n' "python3" "${PY_VERSION}"
fi
if [[ -z "${YQ_VERSION:-}" && -z "${PY_VERSION:-}" ]]; then
  echo "MISSING  yq | python3  (one is required to read/write config.yaml)" >&2
  ERRORS=$((ERRORS + 1))
fi

if [[ "${ERRORS}" -gt 0 ]]; then
  echo ""
  echo "ERROR: ${ERRORS} prerequisite check(s) failed. Resolve the issues above before continuing." >&2
  exit 1
fi

echo ""
echo "All prerequisites satisfied."
