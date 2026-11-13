#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# mas-manage-graphite-extract.sh — For every operator tag, copy
# /graphite/node_modules/@maximo from the graphite-configuration image to
# MANAGE/<tag>/GRAPHITE/node_modules/@maximo and unzip the Graphite app
# definitions from MANAGE/<tag>/SMP/ into MANAGE/<tag>/GRAPHITE/apps/
# ---------------------------------------------------------------------------
# Reads status.operators.<tag>.graphite (written by step 2). MANAGE/<tag>/GRAPHITE
# is cleared first, so it is an exact mirror of that tag's images. Run step 3
# first so MANAGE/<tag>/SMP/ holds the app ZIPs.
#
# Usage: mas-manage-graphite-extract.sh [--tag <operatorTag>]...
# ---------------------------------------------------------------------------
# Prerequisites:
#   - Container engine (docker | podman)
#   - yq (mikefarah) or python3, for reading config.yaml
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG="${REPO_ROOT}/config.yaml"

# shellcheck source=scripts/config-lib.sh
source "${SCRIPT_DIR}/config-lib.sh"
config_parser >/dev/null || exit 1

# Container engine (docker | podman) chosen by container.engine in config.yaml.
# shellcheck source=scripts/container-runtime.sh
source "${SCRIPT_DIR}/container-runtime.sh"
CONTAINER_ENGINE="$(resolve_container_engine "${CONFIG}")" || exit 1

# Parent run: loop over the operator tags and print the combined summary.
run_per_tag "${BASH_SOURCE[0]}" "$@"
if [[ -z "${MAS_CHILD_TAG:-}" ]]; then
  print_run_summary
  exit "${RUN_RC}"
fi

# ---------------------------------------------------------------------------
# Child run: one operator tag (MAS_CHILD_TAG)
# ---------------------------------------------------------------------------
TAG="${MAS_CHILD_TAG}"
TAG_DIR="$(operator_dir "${REPO_ROOT}" "${TAG}")"
GRAPHITE_DIR="${TAG_DIR}/GRAPHITE"
OUTPUT_DIR="${GRAPHITE_DIR}/node_modules/@maximo"
APPS_SRC="${TAG_DIR}/SMP/maximo/tools/maximo/en/graphite/apps"
APPS_OUT="${GRAPHITE_DIR}/apps"
MARKER="${TAG_DIR}/.graphite-source"
CONTAINER_NAME="mas-manage-graphite-${TAG}"

# ---------------------------------------------------------------------------
# 1. Image reference from status.operators.<tag>.graphite
# ---------------------------------------------------------------------------
IMAGE="$(status_image "${CONFIG}" "${TAG}" graphite)"
if [[ -z "${IMAGE}" ]]; then
  echo "ERROR: status.operators.${TAG}.graphite is not set in ${CONFIG}." >&2
  echo "       Run scripts/mas-manage-resolve-image.sh first." >&2
  exit 1
fi
echo "Image: ${IMAGE}"
result "Image" "${IMAGE}"

# ---------------------------------------------------------------------------
# 2. Pull image (no-op if already cached)
# ---------------------------------------------------------------------------
echo "Pulling image (no-op if already cached) ..."
"${CONTAINER_ENGINE}" pull "${IMAGE}" 2>&1 | tail -1

# ---------------------------------------------------------------------------
# 3. Copy /graphite/node_modules/@maximo via tar (handles node_modules symlinks)
# ---------------------------------------------------------------------------
# `<engine> cp` does not handle relative symlinks that point outside the
# extracted tree (common in node_modules/.bin). Using tar inside a short-lived
# --rm container piped to local tar avoids this limitation entirely.
rm -f "${MARKER}"
rm -rf "${GRAPHITE_DIR}"
mkdir -p "${OUTPUT_DIR}"
echo "Copying /graphite/node_modules/@maximo from container (this may take a while) ..."
"${CONTAINER_ENGINE}" run --rm --name "${CONTAINER_NAME}" \
  "${IMAGE}" \
  tar -C /graphite/node_modules -cf - @maximo \
  | tar -xf - -C "$(dirname "${OUTPUT_DIR}")"
echo "Copy complete."
printf '%s\n' "${IMAGE}" > "${MARKER}"

# ---------------------------------------------------------------------------
# 4. Unzip Graphite app definitions from MANAGE/<tag>/SMP into GRAPHITE/apps/
# ---------------------------------------------------------------------------
APP_COUNT=0
if [[ -d "${APPS_SRC}" ]]; then
  mkdir -p "${APPS_OUT}"
  echo "Unzipping Graphite app definitions from ${APPS_SRC} ..."
  while IFS= read -r -d '' zip_file; do
    app_name="$(basename "${zip_file}" .zip)"
    dest="${APPS_OUT}/${app_name}"
    mkdir -p "${dest}"
    unzip -q -o "${zip_file}" -d "${dest}"
    APP_COUNT=$((APP_COUNT + 1))
    # Also unzip app-source.zip if present inside the extracted app directory
    if [[ -f "${dest}/app-source.zip" ]]; then
      unzip -q -o "${dest}/app-source.zip" -d "${dest}"
    fi
  done < <(find "${APPS_SRC}" -maxdepth 1 -name "*.zip" -print0 | sort -z)
  echo "Unzipped ${APP_COUNT} app(s) to ${APPS_OUT}."
else
  echo "WARNING: Graphite apps source not found at ${APPS_SRC}. Run step 3 (SMP extract) for ${TAG} first. Skipping unzip step."
fi

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
FILE_COUNT="$(find "${OUTPUT_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')"

result "Container"        "${CONTAINER_NAME} (--rm)"
result "Files copied"     "${FILE_COUNT}"
result "Output directory" "MANAGE/${TAG}/GRAPHITE/node_modules/@maximo"
result "Apps unzipped"    "${APP_COUNT}"
result "Apps directory"   "MANAGE/${TAG}/GRAPHITE/apps"
