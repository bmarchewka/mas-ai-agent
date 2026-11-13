#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# mas-manage-resolve-image.sh — Resolve manageadmin + graphite images from the
# operator catalog, for every tag in catalog.operatorTag
# ---------------------------------------------------------------------------
# catalog.operatorTag may be a single tag or a list of tags. For each tag the
# OLM file-based catalog image (catalog.operatorImage:<tag>) is pulled, the
# manageadmin and graphite-configuration relatedImage entries are looked up in
# /catalog/ibm-mas-manage/ and /catalog/ibm-mas/, and the results are written
# to config.yaml as:
#
#   status:
#     operators:
#       <tag>:
#         catalogImage: <operatorImage>:<tag>
#         manageadmin:  cp.icr.io/cp/manage/manageadmin:<ver>@sha256:...
#         graphite:     cp.icr.io/cp/mas/graphite-configuration:<ver>@sha256:...
#
# The status block is rebuilt on every run: tags no longer configured are
# dropped, and a tag that fails to resolve keeps its previous entry (if any).
#
# Usage: mas-manage-resolve-image.sh [--tag <operatorTag>]...
# ---------------------------------------------------------------------------
# Prerequisites:
#   - Container engine (docker | podman)
#   - yq (mikefarah) or python3, for reading/writing config.yaml
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

OPERATOR_IMAGE="$(cfg_get "${CONFIG}" catalog operatorImage)"
if [[ -z "${OPERATOR_IMAGE}" ]]; then
  echo "ERROR: could not read catalog.operatorImage from ${CONFIG}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Parent run: loop over the operator tags, then write status.operators
# ---------------------------------------------------------------------------
run_per_tag "${BASH_SOURCE[0]}" "$@"
if [[ -z "${MAS_CHILD_TAG:-}" ]]; then
  # Rebuild status.operators: for every configured tag (config order) use this
  # run's result, else keep the previous entry, else leave it out.
  STATUS_TSV="${RUN_RESULTS_DIR}/status.tsv"
  : > "${STATUS_TSV}"
  WRITTEN=""
  while IFS= read -r tag; do
    [[ -z "${tag}" ]] && continue
    if [[ " ${RUN_TAGS}" == *" ${tag} "* ]] && result_ok "${tag}"; then
      cat_img="$(result_value "${tag}" "Catalog image")"
      mgr_img="$(result_value "${tag}" "Resolved manageadmin")"
      gra_img="$(result_value "${tag}" "Resolved graphite")"
    else
      cat_img="$(status_image "${CONFIG}" "${tag}" catalogImage)"
      mgr_img="$(status_image "${CONFIG}" "${tag}" manageadmin)"
      gra_img="$(status_image "${CONFIG}" "${tag}" graphite)"
    fi
    if [[ -n "${mgr_img}" && -n "${gra_img}" ]]; then
      printf '%s\t%s\t%s\t%s\n' "${tag}" "${cat_img:-${OPERATOR_IMAGE}:${tag}}" "${mgr_img}" "${gra_img}" >> "${STATUS_TSV}"
      WRITTEN="${WRITTEN}${tag} "
    fi
  done <<< "$(operator_tags "${CONFIG}")"
  write_status_operators "${CONFIG}" < "${STATUS_TSV}"

  echo ""
  echo "Written status.operators in config.yaml for: ${WRITTEN:-<none>}"
  print_run_summary
  exit "${RUN_RC}"
fi

# ---------------------------------------------------------------------------
# Child run: resolve one operator tag (MAS_CHILD_TAG)
# ---------------------------------------------------------------------------
# 1. Catalog image for this tag
# ---------------------------------------------------------------------------
CATALOG_TAG="${MAS_CHILD_TAG}"
CATALOG_IMAGE="${OPERATOR_IMAGE}:${CATALOG_TAG}"
CONTAINER_NAME="mas-catalog-${CATALOG_TAG}"

echo "Catalog image: ${CATALOG_IMAGE}"
result "Catalog image" "${CATALOG_IMAGE}"

# ---------------------------------------------------------------------------
# 2. Pull catalog image and create (or reuse) a named container
# ---------------------------------------------------------------------------
echo "Pulling catalog image ..."
"${CONTAINER_ENGINE}" pull "${CATALOG_IMAGE}"

if "${CONTAINER_ENGINE}" inspect --type container "${CONTAINER_NAME}" &>/dev/null; then
  echo "Reusing existing container: ${CONTAINER_NAME}"
else
  echo "Creating container from ${CATALOG_IMAGE} ..."
  "${CONTAINER_ENGINE}" create --name "${CONTAINER_NAME}" "${CATALOG_IMAGE}"
  echo "Container: ${CONTAINER_NAME}"
fi

# ---------------------------------------------------------------------------
# 3. Copy /catalog/ibm-mas-manage/ from the container to a temp directory
# ---------------------------------------------------------------------------
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# Create the destination dirs up front: `docker cp src/. dest/` auto-creates a
# missing dest, but `podman cp` requires it to already exist. Pre-creating works
# identically for both engines.
mkdir -p "${TMPDIR}/catalog-manage" "${TMPDIR}/catalog-mas"

echo "Copying /catalog/ibm-mas-manage/ from container (this may take a while) ..."
"${CONTAINER_ENGINE}" cp "${CONTAINER_NAME}:/catalog/ibm-mas-manage/." "${TMPDIR}/catalog-manage/"
echo "Copying /catalog/ibm-mas/ from container ..."
"${CONTAINER_ENGINE}" cp "${CONTAINER_NAME}:/catalog/ibm-mas/." "${TMPDIR}/catalog-mas/"
echo "Copy complete."

# ---------------------------------------------------------------------------
# 4. Find relatedImage URLs in the YAML bundle files
# ---------------------------------------------------------------------------
# The catalog uses OLM file-based catalog YAML format. Each bundle object file
# contains a relatedImages list where entries look like:
#   - image: cp.icr.io/cp/manage/manageadmin:<tag>@sha256:...
#     name: manage/manageadmin:<tag>
#
# find_image CATALOG_DIR NAME_PREFIX
#   Walks CATALOG_DIR, looks for stable bundle files (no "pre" in name),
#   sorted latest-version first, and returns the image URL for the first
#   relatedImage whose "name:" line starts with NAME_PREFIX.
find_image() {
  local CATALOG_DIR="$1"
  local NAME_PREFIX="$2"

  if command -v python3 &>/dev/null; then
    python3 - "${CATALOG_DIR}" "${NAME_PREFIX}" <<'EOF'
import sys, os, re

catalog_dir  = sys.argv[1]
name_prefix  = sys.argv[2]

def version_key(fname):
    m = re.search(r'v(\d+)\.(\d+)\.(\d+)$', fname.replace('.yaml', ''))
    if m:
        return (int(m.group(1)), int(m.group(2)), int(m.group(3)))
    return None

for root, _, files in os.walk(catalog_dir):
    stable = [f for f in files if 'pre' not in f and version_key(f) is not None]
    stable.sort(key=version_key, reverse=True)
    for fname in stable:
        fpath = os.path.join(root, fname)
        try:
            with open(fpath) as f:
                lines = f.readlines()
            for i, line in enumerate(lines):
                if re.match(r'^\s+name:\s+' + re.escape(name_prefix), line):
                    for j in range(i - 1, max(i - 3, -1), -1):
                        m = re.match(r'^\s*-?\s*image:\s*(\S+)', lines[j])
                        if m:
                            print(m.group(1))
                            sys.exit(0)
        except Exception:
            continue
sys.exit(f"ERROR: relatedImage '{name_prefix}' not found in catalog")
EOF
  else
    find "${CATALOG_DIR}" -type f -name '*.yaml' ! -name '*pre*' \
      | xargs grep -l "name: ${NAME_PREFIX}" 2>/dev/null \
      | head -1 \
      | xargs grep -B1 "name: ${NAME_PREFIX}" 2>/dev/null \
      | grep 'image:' \
      | head -1 \
      | awk '{print $NF}'
  fi
}

echo "Resolving manageadmin image ..."
RESOLVED_MANAGEADMIN="$(find_image "${TMPDIR}/catalog-manage" "manage/manageadmin:")"
if [[ -z "${RESOLVED_MANAGEADMIN}" ]]; then
  echo "ERROR: could not find manageadmin image in catalog" >&2
  exit 1
fi
echo "  manageadmin: ${RESOLVED_MANAGEADMIN}"

echo "Resolving graphite-configuration image ..."
RESOLVED_GRAPHITE="$(find_image "${TMPDIR}/catalog-mas" "mas/graphite-configuration:")"
if [[ -z "${RESOLVED_GRAPHITE}" ]]; then
  echo "ERROR: could not find graphite-configuration image in catalog" >&2
  exit 1
fi
echo "  graphite: ${RESOLVED_GRAPHITE}"

result "Resolved manageadmin" "${RESOLVED_MANAGEADMIN}"
result "Resolved graphite"    "${RESOLVED_GRAPHITE}"
