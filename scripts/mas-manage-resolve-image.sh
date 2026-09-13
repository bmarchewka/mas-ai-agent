#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# mas-manage-resolve-image.sh — Resolve manageadmin image from operator catalog
# ---------------------------------------------------------------------------
# Reads catalog.operatorImage and catalog.operatorTag from config.yaml, pulls
# the OLM file-based catalog image, finds the manageadmin relatedImage entry
# from /catalog/ibm-mas-manage/ (YAML bundle objects), and writes the resolved
# URL to status.manageadmin in config.yaml.
# ---------------------------------------------------------------------------
# Prerequisites:
#   - Docker
#   - jq (optional, python3 or grep fallback)
#   - yq (optional, python3 or sed fallback for writing)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG="${REPO_ROOT}/config.yaml"

# Container engine (docker | podman) chosen by container.engine in config.yaml.
# shellcheck source=scripts/container-runtime.sh
source "${SCRIPT_DIR}/container-runtime.sh"
CONTAINER_ENGINE="$(resolve_container_engine "${CONFIG}")" || exit 1

# ---------------------------------------------------------------------------
# 1. Parse catalog.operatorImage and catalog.operatorTag from config.yaml
# ---------------------------------------------------------------------------
parse_catalog_field() {
  local FIELD="$1"
  if command -v yq &>/dev/null; then
    yq ".catalog.${FIELD}" "${CONFIG}"
  elif command -v python3 &>/dev/null; then
    python3 - "${CONFIG}" "${FIELD}" <<'EOF'
import sys, re

with open(sys.argv[1]) as f:
    lines = f.readlines()

field = sys.argv[2]
in_catalog = False
for line in lines:
    if re.match(r'^catalog\s*:', line):
        in_catalog = True
        continue
    if in_catalog:
        if re.match(r'^\S', line) and not re.match(r'^\s', line):
            break
        m = re.match(r'^\s+' + re.escape(field) + r':\s*(.+)$', line)
        if m:
            print(m.group(1).strip())
            sys.exit(0)

sys.exit(f"ERROR: could not parse catalog.{field} from config.yaml")
EOF
  else
    grep -A10 '^catalog:' "${CONFIG}" \
      | grep "  ${FIELD}:" \
      | awk -F': ' '{print $2}' \
      | awk '{print $1}'
  fi
}

OPERATOR_IMAGE="$(parse_catalog_field operatorImage)"
if [[ -z "${OPERATOR_IMAGE}" ]]; then
  echo "ERROR: could not read catalog.operatorImage from ${CONFIG}" >&2
  exit 1
fi

CATALOG_TAG="$(parse_catalog_field operatorTag)"
if [[ -z "${CATALOG_TAG}" ]]; then
  echo "ERROR: could not read catalog.operatorTag from ${CONFIG}" >&2
  exit 1
fi

CATALOG_IMAGE="${OPERATOR_IMAGE}:${CATALOG_TAG}"
CONTAINER_NAME="mas-catalog-${CATALOG_TAG}"

echo "Catalog image: ${CATALOG_IMAGE}"

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

# ---------------------------------------------------------------------------
# 5. Write resolved images to status.<key> in config.yaml
# ---------------------------------------------------------------------------
# write_status_field KEY VALUE
#   Sets status.<KEY> = VALUE, adding the key if it does not yet exist.
write_status_field() {
  local KEY="$1"
  local VALUE="$2"

  if command -v yq &>/dev/null; then
    yq -i ".status.${KEY} = \"${VALUE}\"" "${CONFIG}"
  elif command -v python3 &>/dev/null; then
    python3 - "${CONFIG}" "${KEY}" "${VALUE}" <<'EOF'
import sys, re

config_path = sys.argv[1]
key         = sys.argv[2]
new_value   = sys.argv[3]

with open(config_path) as f:
    content = f.read()

lines = content.splitlines(keepends=True)
result_lines = []
in_status   = False
key_written = False

for line in lines:
    if re.match(r'^status\s*:', line):
        in_status = True
        result_lines.append(line)
        continue
    if in_status:
        # Leaving the status block
        if re.match(r'^\S', line):
            # Append missing key before leaving the block
            if not key_written:
                result_lines.append(f'  {key}: "{new_value}"\n')
                key_written = True
            in_status = False
        elif re.match(r'^\s+' + re.escape(key) + r':', line):
            line = f'  {key}: "{new_value}"\n'
            key_written = True
    result_lines.append(line)

# Handle status block at end of file with no trailing section
if in_status and not key_written:
    result_lines.append(f'  {key}: "{new_value}"\n')

with open(config_path, 'w') as f:
    f.write(''.join(result_lines))

print(f"Written: {new_value}")
EOF
  else
    # sed fallback — replace if exists
    if grep -q "^  ${KEY}:" "${CONFIG}"; then
      sed -i.bak "s|^\(  ${KEY}:\).*$|\1 \"${VALUE}\"|" "${CONFIG}"
      rm -f "${CONFIG}.bak"
    else
      # Append under status: block
      sed -i.bak "/^status:/a\\  ${KEY}: \"${VALUE}\"" "${CONFIG}"
      rm -f "${CONFIG}.bak"
    fi
    echo "Written: ${VALUE}"
  fi
}

write_status_field "manageadmin" "${RESOLVED_MANAGEADMIN}"
write_status_field "graphite"    "${RESOLVED_GRAPHITE}"

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
echo ""
echo "| Metric                    | Value |"
echo "|---------------------------|-------|"
echo "| Catalog image             | ${CATALOG_IMAGE} |"
echo "| Catalog tag               | ${CATALOG_TAG} |"
echo "| Resolved manageadmin      | ${RESOLVED_MANAGEADMIN} |"
echo "| Resolved graphite         | ${RESOLVED_GRAPHITE} |"
echo "| Written to                | status.manageadmin, status.graphite in config.yaml |"
