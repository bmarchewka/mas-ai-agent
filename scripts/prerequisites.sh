#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# prerequisites.sh — Validate required tools and the config files
# ---------------------------------------------------------------------------
# Every workflow step runs through containers, so the container engine is the
# main host prerequisite. Which engine (docker | podman) is chosen by
# container.engine (config.local.yaml over config.defaults.yaml). Reading the
# config files and writing MANAGE/status.yaml additionally needs yq (mikefarah)
# or python3 — either one is enough. Step 2's catalog resolver prefers python3
# and otherwise runs in a throwaway python container.
#
# Config files: config.defaults.yaml (tracked) is required. config.local.yaml
# (gitignored, your settings) is optional — without it the defaults are used
# and a hint on how to create it is printed. MAS_CONFIG=<file> selects another
# local file.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/config-lib.sh
source "${SCRIPT_DIR}/config-lib.sh"
# shellcheck source=scripts/container-runtime.sh
source "${SCRIPT_DIR}/container-runtime.sh"

ERRORS=0

# Parser for the config files — yq (mikefarah) preferred, python3 as fallback.
if command -v yq &>/dev/null && yq --version 2>/dev/null | grep -q mikefarah; then
  YQ_VERSION="$(yq --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi
if command -v python3 &>/dev/null; then
  PY_VERSION="$(python3 --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi

# Config files. With a parser, load (merge) them like every other step does;
# without one, fall back to a block scan of the file that sets the engine.
if [[ -n "${YQ_VERSION:-}" || -n "${PY_VERSION:-}" ]]; then
  config_init || exit 1
else
  CONFIG_LOCAL="${MAS_CONFIG:-${REPO_ROOT}/config.local.yaml}"
  CONFIG="${REPO_ROOT}/config.defaults.yaml"
  [[ -f "${CONFIG_LOCAL}" ]] && grep -q '^container:' "${CONFIG_LOCAL}" && CONFIG="${CONFIG_LOCAL}"
fi
LOCAL_REL="${CONFIG_LOCAL#"${REPO_ROOT}/"}"

# Container engine (docker | podman) — from container.engine.
ENGINE="$(container_engine_name "${CONFIG}")" || exit 1

if command -v "${ENGINE}" &>/dev/null; then
  ENGINE_VERSION="$("${ENGINE}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  printf 'OK  %-10s %s\n' "${ENGINE}" "${ENGINE_VERSION}"
else
  echo "MISSING  ${ENGINE}      (not found on PATH)" >&2
  ERRORS=$((ERRORS + 1))
fi

[[ -n "${YQ_VERSION:-}" ]] && printf 'OK  %-10s %s\n' "yq" "${YQ_VERSION}"
[[ -n "${PY_VERSION:-}" ]] && printf 'OK  %-10s %s\n' "python3" "${PY_VERSION}"
if [[ -z "${YQ_VERSION:-}" && -z "${PY_VERSION:-}" ]]; then
  echo "MISSING  yq | python3  (one is required to read the config files)" >&2
  ERRORS=$((ERRORS + 1))
fi

if [[ -f "${REPO_ROOT}/config.defaults.yaml" ]]; then
  printf 'OK  %-10s %s\n' "config" "config.defaults.yaml"
else
  echo "MISSING  config.defaults.yaml  (part of the repository: git checkout -- config.defaults.yaml)" >&2
  ERRORS=$((ERRORS + 1))
fi
if [[ -f "${CONFIG_LOCAL}" ]]; then
  printf 'OK  %-10s %s\n' "config" "${LOCAL_REL} (merged over the defaults)"
else
  printf 'NOTE %-9s %s\n' "config" "${LOCAL_REL} not found — running with config.defaults.yaml only."
  echo "     Put your settings (operator tags, database, ...) in it:"
  echo "       cp config.local.example.yaml config.local.yaml"
fi

if [[ "${ERRORS}" -gt 0 ]]; then
  echo ""
  echo "ERROR: ${ERRORS} prerequisite check(s) failed. Resolve the issues above before continuing." >&2
  exit 1
fi

echo ""
echo "All prerequisites satisfied."
