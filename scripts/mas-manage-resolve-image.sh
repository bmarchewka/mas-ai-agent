#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# mas-manage-resolve-image.sh — Resolve the selected Manage and MAS core
# versions of every operator catalog tag to image references
# ---------------------------------------------------------------------------
# config.yaml selects, per operator catalog tag, which versions to extract:
#
#   catalog:
#     operatorImage: icr.io/cpopen/ibm-maximo-operator-catalog
#     operators:
#       v9-260827-amd64:              # nothing set -> manage/core: [latest]
#       v9-261105-amd64:
#         manage: [9.2.x, 9.1.x]      # Manage operator versions (manageadmin image)
#         core:   [9.2.x, 9.1.x]      # MAS core versions (graphite-configuration image)
#
# Each list item is `latest` (newest selectable version in the package's
# defaultChannel), a channel (`9.2.x`, `9.2`, `9.3.x-feature` -> newest
# selectable version in it) or an exact version (`9.2.4`). The legacy
# `catalog.operatorTag: [tag, ...]` form means [latest] for both lists.
#
# For each tag the OLM file-based catalog image (<operatorImage>:<tag>) is
# pulled, /catalog/ibm-mas-manage/ and /catalog/ibm-mas/ are copied out and the
# specs are resolved by scripts/catalog_resolve.py. Results are written to:
#
#   status:
#     operators:
#       <tag>:
#         catalogImage: <operatorImage>:<tag>
#         manage:
#           "<version>": {requested, channel, bundle, source, manageadmin}
#         core:
#           "<version>": {requested, channel, bundle, source, graphite}
#         skipped:
#           core: <specs>      # core items <= 9.0, which ship no Graphite
#
# Image sources (`source`):
#   catalog   the bundle's relatedImages list the image (current catalogs)
#   operator  older catalogs (e.g. v9-250403-amd64) and older patch bundles list
#             only the operator images. The image is then traced through the
#             digests the operators pin for their own release:
#               Manage: ibm-mas-manage -> ibm-mas-manage-primary-entity
#                       -> ibm-mas-manage-ws -> manage/manageadmin
#               core:   ibm-mas -> ibm-mas-suite -> ibm-mas-entitymgr
#                       -> mas/graphite-configuration
#             Only small files are copied out of each operator image (via
#             create + cp; nothing is run), images pulled for this are removed
#             again, and results are cached in tmp/image-trace/.
#
# The status block is rebuilt on every run: tags no longer configured are
# dropped, and a tag whose catalog cannot be read keeps its previous entry.
#
# Usage:
#   mas-manage-resolve-image.sh [--tag <operatorTag>]...
#   mas-manage-resolve-image.sh --list-versions [--tag <operatorTag>]...
#       print the selectable Manage / core versions of each catalog; config.yaml
#       is not changed.
# ---------------------------------------------------------------------------
# Prerequisites:
#   - Container engine (docker | podman)
#   - yq (mikefarah) or python3, for reading/writing config.yaml
#   - python3 for catalog resolution (falls back to a python container)
#   - an IBM entitlement login (`<engine> login cp.icr.io`) for tracing images
#     of older catalogs (the operator sub-images are in cp.icr.io)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG="${REPO_ROOT}/config.yaml"
RESOLVER="${SCRIPT_DIR}/catalog_resolve.py"

# shellcheck source=scripts/config-lib.sh
source "${SCRIPT_DIR}/config-lib.sh"
config_parser >/dev/null || exit 1

# Container engine (docker | podman) chosen by container.engine in config.yaml.
# shellcheck source=scripts/container-runtime.sh
source "${SCRIPT_DIR}/container-runtime.sh"
CONTAINER_ENGINE="$(resolve_container_engine "${CONFIG}")" || exit 1
export CONTAINER_ENGINE

OPERATOR_IMAGE="$(cfg_get "${CONFIG}" catalog operatorImage)"
if [[ -z "${OPERATOR_IMAGE}" ]]; then
  echo "ERROR: could not read catalog.operatorImage from ${CONFIG}" >&2
  exit 1
fi

for arg in "$@"; do
  [[ "${arg}" == "--list-versions" ]] && export MAS_LIST_VERSIONS=1
done

# ---------------------------------------------------------------------------
# Parent run: loop over the operator tags, then rebuild status.operators
# ---------------------------------------------------------------------------
run_units "${BASH_SOURCE[0]}" tag "$@"
if [[ -z "${MAS_CHILD_TAG:-}" ]]; then
  if [[ -n "${MAS_LIST_VERSIONS:-}" ]]; then
    exit "${RUN_RC}"
  fi

  STATUS_ROWS="${RUN_RESULTS_DIR}/status.rows"
  : > "${STATUS_ROWS}"
  KEPT=""
  while IFS= read -r tag; do
    [[ -z "${tag}" ]] && continue
    rows_file="${RUN_RESULTS_DIR}/${tag}.rows"
    if [[ " ${RUN_UNITS}" == *" ${tag} "* && -s "${rows_file}" ]]; then
      cat "${rows_file}" >> "${STATUS_ROWS}"
    else
      # Not run this time, or its catalog could not be read: keep the previous
      # entry when it is in the current (manage/core) format.
      prev="$(cfg_rows "${CONFIG}" status operators "${tag}" | sed 's/^status\t//')"
      if printf '%s\n' "${prev}" | grep -qE $'^operators\t[^\t]+\t(manage|core)\t'; then
        printf '%s\n' "${prev}" >> "${STATUS_ROWS}"
        KEPT="${KEPT}${tag} "
      fi
    fi
  done <<< "$(operator_tags "${CONFIG}")"
  write_status "${CONFIG}" < "${STATUS_ROWS}"

  echo ""
  echo "Written status.operators in config.yaml.${KEPT:+ Kept previous entries for: ${KEPT}}"
  print_run_summary
  exit "${RUN_RC}"
fi

# ---------------------------------------------------------------------------
# Child run: one operator tag (MAS_CHILD_TAG)
# ---------------------------------------------------------------------------
CATALOG_TAG="${MAS_CHILD_TAG}"
CATALOG_IMAGE="${OPERATOR_IMAGE}:${CATALOG_TAG}"
CONTAINER_NAME="mas-catalog-${CATALOG_TAG}"

echo "Catalog image: ${CATALOG_IMAGE}"
result "Catalog image" "${CATALOG_IMAGE}"

# ---------------------------------------------------------------------------
# 1. Pull catalog image and create (or reuse) a named container
# ---------------------------------------------------------------------------
echo "Pulling catalog image ..."
"${CONTAINER_ENGINE}" pull "${CATALOG_IMAGE}"

if "${CONTAINER_ENGINE}" inspect --type container "${CONTAINER_NAME}" &>/dev/null; then
  echo "Reusing existing container: ${CONTAINER_NAME}"
else
  echo "Creating container from ${CATALOG_IMAGE} ..."
  "${CONTAINER_ENGINE}" create --name "${CONTAINER_NAME}" "${CATALOG_IMAGE}"
fi

# ---------------------------------------------------------------------------
# 2. Copy the Manage and MAS core catalog folders
# ---------------------------------------------------------------------------
# Under the repo's (gitignored) tmp/ rather than /tmp, so the python-container
# fallback of run_python can mount it (Podman on macOS only shares $HOME).
mkdir -p "${REPO_ROOT}/tmp"
CATALOG_DIR="$(mktemp -d "${REPO_ROOT}/tmp/catalog-${CATALOG_TAG}.XXXXXX")"
trap 'rm -rf "${CATALOG_DIR}"' EXIT

# Pre-create the destinations: `podman cp` requires them to exist.
mkdir -p "${CATALOG_DIR}/ibm-mas-manage" "${CATALOG_DIR}/ibm-mas"
echo "Copying /catalog/ibm-mas-manage/ and /catalog/ibm-mas/ from container ..."
"${CONTAINER_ENGINE}" cp "${CONTAINER_NAME}:/catalog/ibm-mas-manage/." "${CATALOG_DIR}/ibm-mas-manage/"
"${CONTAINER_ENGINE}" cp "${CONTAINER_NAME}:/catalog/ibm-mas/." "${CATALOG_DIR}/ibm-mas/"

if [[ -n "${MAS_LIST_VERSIONS:-}" ]]; then
  echo ""
  run_python "${RESOLVER}" list "${CATALOG_DIR}"
  echo "(via operator) = image not listed in this catalog; it is traced from the operator images when selected."
  exit 0
fi

# ---------------------------------------------------------------------------
# Image tracing for bundles whose relatedImages lack the image (older catalogs)
# ---------------------------------------------------------------------------
ENTITLED_REGISTRY="${MAS_ENTITLED_REGISTRY:-cp.icr.io/cp}"
TRACE_CACHE="${REPO_ROOT}/tmp/image-trace"
TRACE_PULLED=""
TRACE_ERROR=""
TRACE_ABSENT=""   # set when a release provably ships no such image (core: no Graphite)
TRACE_MISSING_ENTRY=""

# trace_pull IMAGE — pull unless present; remembers what was pulled for cleanup.
trace_pull() {
  "${CONTAINER_ENGINE}" image inspect "$1" &>/dev/null && return 0
  "${CONTAINER_ENGINE}" pull -q --platform linux/amd64 "$1" >/dev/null || return 1
  TRACE_PULLED="${TRACE_PULLED}$1 "
}

# trace_file IMAGE PATH DEST — copy one file out of IMAGE without running it.
trace_file() {
  local cid
  trace_pull "$1" || { TRACE_ERROR="cannot pull $1 (logged in to ${ENTITLED_REGISTRY%%/*}?)"; return 1; }
  cid="$("${CONTAINER_ENGINE}" create --platform linux/amd64 "$1" x 2>/dev/null)" \
    || { TRACE_ERROR="cannot create a container from $1"; return 1; }
  if ! "${CONTAINER_ENGINE}" cp "${cid}:$2" "$3" &>/dev/null; then
    "${CONTAINER_ENGINE}" rm "${cid}" &>/dev/null || true
    TRACE_ERROR="$1 has no $2"
    return 1
  fi
  "${CONTAINER_ENGINE}" rm "${cid}" &>/dev/null || true
}

# trace_cleanup — remove the operator images pulled only for tracing.
trace_cleanup() {
  local img
  for img in ${TRACE_PULLED}; do
    "${CONTAINER_ENGINE}" rmi "${img}" &>/dev/null || true
  done
  TRACE_PULLED=""
}

# trace_hop IMAGE FILE MODE ARGS... — sets HOP_OUT to the lookup result for FILE
# in IMAGE. (Globals instead of stdout: command substitution would run in a
# subshell and lose TRACE_ERROR / TRACE_PULLED.)
trace_hop() {
  local image="$1" file="$2"; shift 2
  local local_file
  HOP_OUT=""
  local_file="${CATALOG_DIR}/trace/$(basename "${file}")"
  mkdir -p "${CATALOG_DIR}/trace"
  rm -f "${local_file}"
  trace_file "${image}" "${file}" "${local_file}" || return 1
  if ! HOP_OUT="$(run_python "${RESOLVER}" lookup "${local_file}" "$@")"; then
    TRACE_ERROR="$(basename "${file}") in ${image} has no entry for $*"
    TRACE_MISSING_ENTRY=1
    return 1
  fi
}

# trace_absent CACHE_FILE MESSAGE — record (and cache) that the release has no such image.
trace_absent() {
  TRACE_ABSENT="$2"
  mkdir -p "${TRACE_CACHE}"
  printf 'ABSENT:%s\n' "$2" > "$1"
}

# trace_image KIND VERSION OPERATOR_IMAGE — sets TRACE_REF to the traced image.
trace_image() {
  local kind="$1" version="$2" op="$3"
  local cache_file="${TRACE_CACHE}/${kind}-${version}-${op##*sha256:}"
  TRACE_REF=""
  TRACE_ERROR=""
  TRACE_ABSENT=""
  if [[ -s "${cache_file}" ]]; then
    TRACE_REF="$(cat "${cache_file}")"
    if [[ "${TRACE_REF}" == ABSENT:* ]]; then
      TRACE_ABSENT="${TRACE_REF#ABSENT:}"
      TRACE_REF=""
      return 1
    fi
    return 0
  fi
  local d2 n2 d3 t3 n3
  if [[ "${kind}" == "manage" ]]; then
    # The operator's map of supported releases, else the image it pins for its own release.
    trace_hop "${op}" /opt/ansible/roles/application/vars/supported-images.yml \
      map manage/ibm-mas-manage-primary-entity "${version}" \
      || trace_hop "${op}" /opt/ansible/roles/application/vars/images-with-digests.yml image primaryEntity \
      || return 1
    HOP_OUT="${HOP_OUT%%$'\t'*}"
    trace_hop "${ENTITLED_REGISTRY}/manage/ibm-mas-manage-primary-entity@${HOP_OUT}" \
      /opt/ansible/roles/primary-entity-application/vars/images-with-digests.yml image workspacemgr || return 1
    IFS=$'\t' read -r d2 _ n2 <<< "${HOP_OUT}"
    trace_hop "${ENTITLED_REGISTRY}/${n2:-manage/ibm-mas-manage-ws}@${d2}" \
      /opt/ansible/roles/managebuild/vars/images-with-digests.yml image manageadmin || return 1
    IFS=$'\t' read -r d3 t3 n3 <<< "${HOP_OUT}"
    n3="${n3:-manage/manageadmin}"
  else
    trace_hop "${op}" /opt/ansible/roles/suite/vars/supported-images.yml \
      map mas/ibm-mas-suite "${version}" \
      || trace_hop "${op}" /opt/ansible/roles/suite/vars/images-with-digests.yml image suite \
      || return 1
    HOP_OUT="${HOP_OUT%%$'\t'*}"
    # A suite without the appcfg manager, or an appcfg without graphiteconfiguration,
    # is a release that ships no Graphite (early 9.1 pre-releases): not an error.
    TRACE_MISSING_ENTRY=""
    if ! trace_hop "${ENTITLED_REGISTRY}/mas/ibm-mas-suite@${HOP_OUT}" \
        /opt/ansible/roles/suite/vars/images-with-digests.yml image appcfg; then
      [[ -n "${TRACE_MISSING_ENTRY}" ]] && trace_absent "${cache_file}" "this MAS core release ships no Graphite (no appcfg manager)"
      return 1
    fi
    IFS=$'\t' read -r d2 _ n2 <<< "${HOP_OUT}"
    TRACE_MISSING_ENTRY=""
    if ! trace_hop "${ENTITLED_REGISTRY}/${n2:-mas/ibm-mas-entitymgr}@${d2}" \
        /opt/ansible/ibm-mas-cfg-app/roles/appcfg/vars/images-with-digests.yml image graphiteconfiguration; then
      [[ -n "${TRACE_MISSING_ENTRY}" ]] && trace_absent "${cache_file}" "this MAS core release ships no Graphite (no graphite-configuration image)"
      return 1
    fi
    IFS=$'\t' read -r d3 t3 n3 <<< "${HOP_OUT}"
    n3="${n3:-mas/graphite-configuration}"
  fi
  TRACE_REF="${ENTITLED_REGISTRY}/${n3}${t3:+:${t3}}@${d3}"
  mkdir -p "${TRACE_CACHE}"
  printf '%s\n' "${TRACE_REF}" > "${cache_file}"
}

# ---------------------------------------------------------------------------
# 3. Resolve the manage and core version specs
# ---------------------------------------------------------------------------
ROWS_FILE="$(result_rows_file)"
: > "${ROWS_FILE}"
printf 'operators\t%s\tcatalogImage\t%s\n' "${CATALOG_TAG}" "${CATALOG_IMAGE}" >> "${ROWS_FILE}"

FAILED=0
for kind in manage core; do
  specs="$(operator_specs "${CONFIG}" "${CATALOG_TAG}" "${kind}")" || exit 1
  # shellcheck disable=SC2086
  raw="$(run_python "${RESOLVER}" resolve "${CATALOG_DIR}" "${kind}" ${specs})" || FAILED=1
  if [[ "${kind}" == "manage" ]]; then image_key="manageadmin"; label="Manage"; else image_key="graphite"; label="Core (graphite)"; fi

  # Trace images the catalog does not list (column 8 = source).
  out=""
  skipped=""
  while IFS=$'\t' read -r state k spec version channel bundle image; do
    [[ -z "${state}" ]] && continue
    case "${state}" in
      OK)
        source="catalog"
        if [[ "${image}" == trace:* ]]; then
          source="operator"
          echo "  Tracing ${kind} ${version} image via the operator images (not listed in this catalog) ..."
          if ! trace_image "${kind}" "${version}" "${image#trace:}" < /dev/null; then
            trace_cleanup
            if [[ -n "${TRACE_ABSENT}" ]]; then
              echo "  NOTE: ${kind} '${spec}' skipped: ${version}: ${TRACE_ABSENT}"
              skipped="${skipped:+${skipped}, }${spec}"
              out="${out}SKIP"$'\t'"${k}"$'\t'"${spec}"$'\n'
              continue
            fi
            FAILED=1
            out="${out}ERROR"$'\t'"${k}"$'\t'"${spec}"$'\t'"${version}: cannot trace the ${image_key} image: ${TRACE_ERROR:-unknown error}"$'\n'
            continue
          fi
          trace_cleanup
          image="${TRACE_REF}"
        fi
        out="${out}OK"$'\t'"${k}"$'\t'"${spec}"$'\t'"${version}"$'\t'"${channel}"$'\t'"${bundle}"$'\t'"${image}"$'\t'"${source}"$'\n'
        ;;
      SKIP)
        # $version holds the message for SKIP / ERROR rows.
        echo "  NOTE: ${kind} '${spec}' skipped: ${version}"
        skipped="${skipped:+${skipped}, }${spec}"
        out="${out}SKIP"$'\t'"${k}"$'\t'"${spec}"$'\n'
        ;;
      *)
        out="${out}${state}"$'\t'"${k}"$'\t'"${spec}"$'\t'"${version}"$'\n'
        ;;
    esac
  done <<< "${raw}"
  out="${out%$'\n'}"
  if [[ -n "${skipped}" ]]; then
    printf 'operators\t%s\tskipped\t%s\t%s\n' "${CATALOG_TAG}" "${kind}" "${skipped}" >> "${ROWS_FILE}"
  fi

  # Report errors; merge specs that resolve to the same version ("latest, 9.2.x").
  while IFS=$'\t' read -r state _ spec message; do
    [[ "${state}" == "ERROR" ]] && echo "ERROR: ${kind} '${spec}': ${message}" >&2
  done <<< "${out}"

  printf '%s\n' "${out}" | awk -F'\t' -v tag="${CATALOG_TAG}" -v kind="${kind}" -v key="${image_key}" '
    $1 == "OK" {
      v = $4
      if (!(v in req)) { order[++n] = v; req[v] = $3; chan[v] = $5; bun[v] = $6; img[v] = $7; src[v] = $8 }
      else req[v] = req[v] ", " $3
    }
    END {
      for (i = 1; i <= n; i++) {
        v = order[i]; p = "operators\t" tag "\t" kind "\t" v "\t"
        print p "requested\t" req[v]; print p "channel\t" chan[v]
        print p "bundle\t" bun[v];    print p "source\t" src[v]
        print p key "\t" img[v]
      }
    }' >> "${ROWS_FILE}"

  summary="$(printf '%s\n' "${out}" | awk -F'\t' '
    $1 == "OK" && !seen[$4]++ {
      build = $7; sub(/@.*/, "", build); sub(/.*:/, "", build); sub(/-(amd64|arm64|ppc64le|s390x)$/, "", build)
      s = s (s ? ", " : "") $4 " (" build ($8 == "operator" ? ", via operator" : "") ")"
    }
    $1 == "SKIP"  { s = s (s ? ", " : "") $3 " → skipped (no Graphite in that core release)" }
    $1 == "ERROR" { s = s (s ? ", " : "") $3 " → ERROR" }
    END { print s }')"
  echo "  ${label}: ${summary:-none requested}"
  result "${label}" "${summary}"
done

exit "${FAILED}"
