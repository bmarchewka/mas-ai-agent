#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# mas-manage-graphite-extract.sh — Copy /graphite/node_modules/@maximo from
# the graphite-configuration container to local GRAPHITE/node_modules/@maximo
# ---------------------------------------------------------------------------
# Prerequisites:
#   - Docker
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG="${REPO_ROOT}/config.yaml"
OUTPUT_DIR="${REPO_ROOT}/MANAGE/GRAPHITE/node_modules/@maximo"

# Container engine (docker | podman) chosen by container.engine in config.yaml.
# shellcheck source=scripts/container-runtime.sh
source "${SCRIPT_DIR}/container-runtime.sh"
CONTAINER_ENGINE="$(resolve_container_engine "${CONFIG}")" || exit 1

# ---------------------------------------------------------------------------
# 1. Parse image reference from config.yaml
# ---------------------------------------------------------------------------
parse_image() {
  if command -v yq &>/dev/null; then
    yq '.status.graphite' "${CONFIG}"
  elif command -v python3 &>/dev/null; then
    python3 - "${CONFIG}" <<'EOF'
import sys, re

with open(sys.argv[1]) as f:
    lines = f.readlines()

in_status = False
for line in lines:
    if re.match(r'^status\s*:', line):
        in_status = True
        continue
    if in_status:
        if re.match(r'^\S', line) and not re.match(r'^\s', line):
            break
        m = re.match(r'^\s+graphite:\s*(.+)$', line)
        if m:
            val = m.group(1).strip().strip('"')
            if val:
                print(val)
                sys.exit(0)

sys.exit("ERROR: could not parse status.graphite from config.yaml")
EOF
  else
    grep -A5 '^status:' "${CONFIG}" \
      | grep 'graphite:' \
      | awk -F': ' '{print $2}' \
      | awk '{print $1}'
  fi
}

IMAGE="$(parse_image)"
if [[ -z "${IMAGE}" ]]; then
  echo "ERROR: could not read status.graphite from ${CONFIG}. Run scripts/mas-manage-resolve-image.sh first." >&2
  exit 1
fi

echo "Image: ${IMAGE}"

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
mkdir -p "${OUTPUT_DIR}"
echo "Copying /graphite/node_modules/@maximo from container (this may take a while) ..."
"${CONTAINER_ENGINE}" run --rm --name mas-manage-graphite \
  "${IMAGE}" \
  tar -C /graphite/node_modules -cf - @maximo \
  | tar -xf - -C "$(dirname "${OUTPUT_DIR}")"
echo "Copy complete."

# ---------------------------------------------------------------------------
# 4. Unzip Graphite app definitions from SMP into MANAGE/GRAPHITE/apps/
# ---------------------------------------------------------------------------
APPS_SRC="${REPO_ROOT}/MANAGE/SMP/maximo/tools/maximo/en/graphite/apps"
APPS_OUT="${REPO_ROOT}/MANAGE/GRAPHITE/apps"

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
  echo "WARNING: Graphite apps source not found at ${APPS_SRC}. Skipping unzip step."
fi

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
FILE_COUNT="$(find "${OUTPUT_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')"

echo ""
echo "| Metric           | Value |"
echo "|------------------|-------|"
echo "| Image            | ${IMAGE} |"
echo "| Container        | mas-manage-graphite (--rm) |"
echo "| Files copied     | ${FILE_COUNT} |"
echo "| Output directory | MANAGE/GRAPHITE/node_modules/@maximo |"
echo "| Apps unzipped    | ${APP_COUNT} |"
echo "| Apps directory   | MANAGE/GRAPHITE/apps |"
