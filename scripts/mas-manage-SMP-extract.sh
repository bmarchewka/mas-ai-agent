#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# mas-manage-SMP-extract.sh — Mirror /opt/IBM/SMP/ from the manageadmin container
# ---------------------------------------------------------------------------
# Copies the SMP tree verbatim into MANAGE/SMP/. Files — including compiled
# .class files — are kept exactly as shipped in the image; nothing is
# transformed.
#
# Prerequisites:
#   - Docker
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG="${REPO_ROOT}/config.yaml"
OUTPUT_DIR="${REPO_ROOT}/MANAGE/SMP"

# Container engine (docker | podman) chosen by container.engine in config.yaml.
# shellcheck source=scripts/container-runtime.sh
source "${SCRIPT_DIR}/container-runtime.sh"
CONTAINER_ENGINE="$(resolve_container_engine "${CONFIG}")" || exit 1

# ---------------------------------------------------------------------------
# 1. Parse image reference from config.yaml
# ---------------------------------------------------------------------------
parse_image() {
  if command -v yq &>/dev/null; then
    yq '.status.manageadmin' "${CONFIG}"
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
        # Stop at next top-level key
        if re.match(r'^\S', line) and not re.match(r'^\s', line):
            break
        m = re.match(r'^\s+manageadmin:\s*(.+)$', line)
        if m:
            val = m.group(1).strip().strip('"')
            if val:
                print(val)
                sys.exit(0)

sys.exit("ERROR: could not parse status.manageadmin from config.yaml")
EOF
  else
    # grep/awk fallback — match the resolved image registry (cp.icr.io)
    grep -A5 '^status:' "${CONFIG}" \
      | grep 'manageadmin:' \
      | awk -F': ' '{print $2}' \
      | awk '{print $1}'
  fi
}

IMAGE="$(parse_image)"
if [[ -z "${IMAGE}" ]]; then
  echo "ERROR: could not read status.manageadmin from ${CONFIG}. Run scripts/mas-manage-resolve-image.sh first." >&2
  exit 1
fi

echo "Image: ${IMAGE}"

# ---------------------------------------------------------------------------
# 2. Create or reuse named container
# ---------------------------------------------------------------------------
# Derive version from the image tag (everything after the last ':')
IMAGE_TAG="${IMAGE##*:}"
CONTAINER_NAME="mas-manageadmin-${IMAGE_TAG}"

if "${CONTAINER_ENGINE}" inspect --type container "${CONTAINER_NAME}" &>/dev/null; then
  echo "Reusing existing container: ${CONTAINER_NAME}"
else
  echo "Creating container from ${IMAGE} ..."
  "${CONTAINER_ENGINE}" create --name "${CONTAINER_NAME}" "${IMAGE}"
  echo "Container: ${CONTAINER_NAME}"
fi

# ---------------------------------------------------------------------------
# 3. Copy entire /opt/IBM/SMP/ from container → MANAGE/SMP/
# ---------------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"
echo "Copying /opt/IBM/SMP/ from container (this may take a while) ..."
"${CONTAINER_ENGINE}" cp "${CONTAINER_NAME}:/opt/IBM/SMP/." "${OUTPUT_DIR}/"
echo "Copy complete."

# ---------------------------------------------------------------------------
# 4. Summary
# ---------------------------------------------------------------------------
CLASS_COUNT="$(find "${OUTPUT_DIR}" -name "*.class" 2>/dev/null | wc -l | tr -d ' ')"
FILE_COUNT="$(find "${OUTPUT_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')"

echo ""
echo "Done. ${FILE_COUNT} total files in MANAGE/SMP/ (${CLASS_COUNT} .class files kept as-is)."
echo ""
echo "| Metric      | Value |"
echo "|-------------|-------|"
echo "| Image       | ${IMAGE} |"
echo "| Container   | ${CONTAINER_NAME} |"
echo "| Class files | ${CLASS_COUNT} |"
echo "| Total files | ${FILE_COUNT} |"
