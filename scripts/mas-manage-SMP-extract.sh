#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# mas-manage-SMP-extract.sh — Mirror /opt/IBM/SMP/ from the manageadmin image
# of every resolved Manage version into MANAGE/<tag>/manage-<version>/SMP/
# ---------------------------------------------------------------------------
# For each operator tag and each Manage version resolved by step 2
# (status.operators.<tag>.manage.<version>.manageadmin in MANAGE/status.yaml), copies the SMP tree
# verbatim. Files — including compiled .class files — are kept exactly as
# shipped in the image; nothing is transformed. The folder is cleared first,
# so it is an exact mirror of that image.
#
# If another folder was already extracted from the very same manageadmin image
# (same digest — e.g. the same Manage version in two catalogs), the tree is
# copied locally from there instead of from a container.
#
# Each MANAGE/<tag>/manage-<version>/ also gets an images.yaml manifest.
#
# Usage: mas-manage-SMP-extract.sh [--tag <operatorTag>]... [--version <version>]...
# ---------------------------------------------------------------------------
# Prerequisites:
#   - Container engine (docker | podman)
#   - yq (mikefarah) or python3, for reading the config files
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/config-lib.sh
source "${SCRIPT_DIR}/config-lib.sh"
config_init || exit 1     # config.local.yaml over config.defaults.yaml -> CONFIG

# Container engine (docker | podman) chosen by container.engine.
# shellcheck source=scripts/container-runtime.sh
source "${SCRIPT_DIR}/container-runtime.sh"
CONTAINER_ENGINE="$(resolve_container_engine "${CONFIG}")" || exit 1

# Parent run: loop over (tag, Manage version) and print the combined summary.
run_units "${BASH_SOURCE[0]}" manage "$@"
if [[ -z "${MAS_CHILD_TAG:-}" ]]; then
  print_run_summary
  exit "${RUN_RC}"
fi

# ---------------------------------------------------------------------------
# Child run: one (tag, Manage version)
# ---------------------------------------------------------------------------
TAG="${MAS_CHILD_TAG}"
VERSION="${MAS_CHILD_VERSION}"
UNIT_DIR="$(unit_dir "${REPO_ROOT}" "${TAG}" manage "${VERSION}")"
UNIT_REL="${UNIT_DIR#"${REPO_ROOT}/"}"
OUTPUT_DIR="${UNIT_DIR}/SMP"
MARKER="${UNIT_DIR}/.smp-source"

# ---------------------------------------------------------------------------
# 1. Image reference from status.operators.<tag>.manage.<version>.manageadmin
# ---------------------------------------------------------------------------
IMAGE="$(status_field "${TAG}" manage "${VERSION}" manageadmin)"
if [[ -z "${IMAGE}" ]]; then
  echo "ERROR: status.operators.${TAG}.manage.${VERSION}.manageadmin is not set in MANAGE/status.yaml." >&2
  echo "       Run scripts/mas-manage-resolve-image.sh first." >&2
  exit 1
fi
echo "Image: ${IMAGE}"
result "Image" "${IMAGE}"

# ---------------------------------------------------------------------------
# 2. Look for another folder already extracted from the same image
# ---------------------------------------------------------------------------
REUSE_FROM=""
for other_marker in "${REPO_ROOT}"/MANAGE/*/manage-*/.smp-source; do
  [[ -f "${other_marker}" ]] || continue
  other_dir="$(dirname "${other_marker}")"
  [[ "${other_dir}" == "${UNIT_DIR}" ]] && continue
  if [[ -d "${other_dir}/SMP" && "$(cat "${other_marker}")" == "${IMAGE}" ]]; then
    REUSE_FROM="${other_dir}"
    break
  fi
done

# ---------------------------------------------------------------------------
# 3. Copy /opt/IBM/SMP/ → MANAGE/<tag>/manage-<version>/SMP/ (fresh mirror)
# ---------------------------------------------------------------------------
rm -f "${MARKER}"
rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

if [[ -n "${REUSE_FROM}" ]]; then
  echo "Same manageadmin image already extracted in ${REUSE_FROM#"${REPO_ROOT}/"} — copying locally ..."
  cp -Rp "${REUSE_FROM}/SMP/." "${OUTPUT_DIR}/"
  CONTAINER_LABEL="(copied from ${REUSE_FROM#"${REPO_ROOT}/"}/SMP)"
else
  # Container named after the image tag/digest (everything after the last ':').
  IMAGE_TAG="${IMAGE##*:}"
  CONTAINER_NAME="mas-manageadmin-${IMAGE_TAG}"
  if "${CONTAINER_ENGINE}" inspect --type container "${CONTAINER_NAME}" &>/dev/null; then
    echo "Reusing existing container: ${CONTAINER_NAME}"
  else
    echo "Creating container from ${IMAGE} ..."
    "${CONTAINER_ENGINE}" create --name "${CONTAINER_NAME}" "${IMAGE}"
    echo "Container: ${CONTAINER_NAME}"
  fi
  echo "Copying /opt/IBM/SMP/ from container (this may take a while) ..."
  "${CONTAINER_ENGINE}" cp "${CONTAINER_NAME}:/opt/IBM/SMP/." "${OUTPUT_DIR}/"
  CONTAINER_LABEL="${CONTAINER_NAME}"
fi
echo "Copy complete."
printf '%s\n' "${IMAGE}" > "${MARKER}"

# ---------------------------------------------------------------------------
# 4. Manifest: MANAGE/<tag>/manage-<version>/images.yaml
# ---------------------------------------------------------------------------
cat > "${UNIT_DIR}/images.yaml" <<EOF
# Generated by mas-agent — what this folder was extracted from.
operatorTag: "${TAG}"
catalogImage: "$(status_get "${TAG}" catalogImage)"
package: ibm-mas-manage
version: "${VERSION}"
requested: "$(status_field "${TAG}" manage "${VERSION}" requested)"
channel: "$(status_field "${TAG}" manage "${VERSION}" channel)"
bundle: "$(status_field "${TAG}" manage "${VERSION}" bundle)"
source: "$(status_field "${TAG}" manage "${VERSION}" source)"
manageadmin: "${IMAGE}"
EOF

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
CLASS_COUNT="$(find "${OUTPUT_DIR}" -name "*.class" 2>/dev/null | wc -l | tr -d ' ')"
FILE_COUNT="$(find "${OUTPUT_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')"

echo "Done. ${FILE_COUNT} total files in ${UNIT_REL}/SMP/ (${CLASS_COUNT} .class files kept as-is)."

result "Container"        "${CONTAINER_LABEL}"
result "Class files"      "${CLASS_COUNT}"
result "Total files"      "${FILE_COUNT}"
result "Output directory" "${UNIT_REL}/SMP/"
