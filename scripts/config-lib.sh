#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# config-lib.sh — Shared config.yaml helpers + per-tag / per-version runner
# ---------------------------------------------------------------------------
# Sourced by the workflow scripts. Provides:
#   cfg_get   CONFIG KEY...          scalar value ("" when absent/null)
#   cfg_list  CONFIG KEY...          one item per line (list, or comma-split scalar)
#   cfg_keys  CONFIG KEY...          keys of a map, one per line
#   cfg_rows  CONFIG KEY...          every leaf below KEY: key<TAB>...<TAB>value
#   cfg_bool  CONFIG DEFAULT KEY...  "true" | "false" (errors on other values)
#   operator_tags  CONFIG            configured operator catalog tags
#   operator_specs CONFIG TAG KIND   version specs for KIND (manage | core) of TAG
#   status_versions CONFIG TAG KIND  resolved versions in status.operators.<TAG>.<KIND>
#   status_field   CONFIG TAG KIND VERSION FIELD
#   write_status   CONFIG            rewrite `status` from leaf rows on stdin
#                                    (key<TAB>...<TAB>value, relative to status)
#   unit_dir REPO_ROOT TAG KIND VERSION   MANAGE/<TAG>/<KIND>-<VERSION>
#   run_python SCRIPT ARGS...        python3 on the host, else in a container
#   run_units  SCRIPT MODE ARGS...   run SCRIPT once per tag / (tag, version)
#   result KEY VALUE                 record a summary row (inside a unit run)
#
# Keys are passed as separate arguments (cfg_get "$CONFIG" masManage database host)
# so operator tags and versions containing dots are handled safely.
#
# config.yaml — operator catalog selection (either form):
#   catalog:
#     operators:                       # preferred
#       v9-260827-amd64:               #   nothing set -> manage/core: [latest]
#       v9-261105-amd64:
#         manage: [9.2.x, 9.1.x]
#         core:   [9.2.x, 9.1.x]
#     operatorTag: [v9-260827-amd64]   # legacy: each tag -> manage/core: [latest]
#
# Parsing uses the mikefarah `yq` binary when present, else python3 with the
# bundled scripts/config_yaml.py. One of the two is required (checked by
# scripts/prerequisites.sh).
#
# Bash 3.2 compatible (stock macOS): no associative arrays or mapfile.
# ---------------------------------------------------------------------------

CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# OCI tag / version charset; also keeps generated yq expressions and paths safe.
_CFG_KEY_RE='^[A-Za-z0-9._-]+$'

# python image used when the host has no python3 (same as step 5).
MAS_PYTHON_IMAGE="${MAS_PYTHON_IMAGE:-python:3.12-slim-bookworm}"

_cfg_has_yq() {
  command -v yq &>/dev/null && yq --version 2>/dev/null | grep -q 'mikefarah'
}

# Name the parser in use, or fail with a clear message when none is available.
config_parser() {
  if _cfg_has_yq; then
    printf 'yq'
  elif command -v python3 &>/dev/null; then
    printf 'python3'
  else
    echo "ERROR: reading config.yaml needs either yq (mikefarah, https://github.com/mikefarah/yq) or python3 on PATH." >&2
    return 1
  fi
}

_cfg_yq_path() {
  local path="" k
  for k in "$@"; do
    if [[ ! "${k}" =~ ${_CFG_KEY_RE} ]]; then
      echo "ERROR: invalid config key '${k}'" >&2
      return 1
    fi
    path="${path}[\"${k}\"]"
  done
  printf '.%s' "${path}"
}

_cfg_py() {
  python3 -I "${CONFIG_LIB_DIR}/config_yaml.py" "$@"
}

cfg_get() {
  local config="$1"; shift
  local parser out path
  parser="$(config_parser)" || return 1
  if [[ "${parser}" == "yq" ]]; then
    path="$(_cfg_yq_path "$@")" || return 1
    out="$(yq "${path} | select(tag != \"!!map\" and tag != \"!!seq\")" "${config}" 2>/dev/null || true)"
  else
    out="$(_cfg_py get "${config}" "$@")" || return 1
  fi
  [[ "${out}" == "null" ]] && out=""
  printf '%s' "${out}"
}

cfg_list() {
  local config="$1"; shift
  local parser path
  parser="$(config_parser)" || return 1
  if [[ "${parser}" == "yq" ]]; then
    path="$(_cfg_yq_path "$@")" || return 1
    yq "[${path}] | flatten | .[] | select(. != null)" "${config}" 2>/dev/null \
      | tr ',' '\n' \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      | grep -v '^$' || true
  else
    _cfg_py list "${config}" "$@"
  fi
}

cfg_keys() {
  local config="$1"; shift
  local parser path
  parser="$(config_parser)" || return 1
  if [[ "${parser}" == "yq" ]]; then
    path="$(_cfg_yq_path "$@")" || return 1
    yq "${path} | select(tag == \"!!map\") | keys | .[]" "${config}" 2>/dev/null || true
  else
    _cfg_py keys "${config}" "$@"
  fi
}

cfg_rows() {
  local config="$1"; shift
  local parser path
  parser="$(config_parser)" || return 1
  if [[ "${parser}" == "yq" ]]; then
    path="$(_cfg_yq_path "$@")" || return 1
    yq "${path} | .. | select(tag != \"!!map\" and tag != \"!!seq\" and tag != \"!!null\") | ((path | join(\"\t\")) + \"\t\" + (. | tostring))" "${config}" 2>/dev/null || true
  else
    _cfg_py rows "${config}" "$@"
  fi
}

# cfg_bool CONFIG DEFAULT KEY...  -> prints "true" or "false".
# true/yes/on/1 -> true; false/no/off/0 -> false; absent/empty -> DEFAULT.
cfg_bool() {
  local config="$1" default="$2"; shift 2
  local raw
  raw="$(cfg_get "${config}" "$@")" || return 1
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]"'"'")"
  case "${raw}" in
    "")                   printf '%s' "${default}" ;;
    true | yes | on | 1)  printf 'true' ;;
    false | no | off | 0) printf 'false' ;;
    *)
      local IFS=.
      echo "ERROR: $*='${raw}' in ${config} is not a boolean (use true or false)." >&2
      return 1
      ;;
  esac
}

_validate_items() {
  local what="$1" item seen=" "
  while IFS= read -r item; do
    [[ -z "${item}" ]] && continue
    if [[ ! "${item}" =~ ${_CFG_KEY_RE} ]]; then
      echo "ERROR: invalid ${what} '${item}' in config.yaml" >&2
      return 1
    fi
    [[ "${seen}" == *" ${item} "* ]] && continue
    seen="${seen}${item} "
    printf '%s\n' "${item}"
  done
}

# Configured operator catalog tags: keys of catalog.operators, else the legacy
# catalog.operatorTag list. De-duplicated, validated.
operator_tags() {
  local config="$1" tags
  tags="$(cfg_keys "${config}" catalog operators)" || return 1
  if [[ -z "${tags}" ]]; then
    tags="$(cfg_list "${config}" catalog operatorTag)" || return 1
  fi
  printf '%s\n' "${tags}" | _validate_items "operator tag"
}

# Version specs for KIND (manage | core) of TAG; "latest" when none are set.
operator_specs() {
  local config="$1" tag="$2" kind="$3" specs
  specs="$(cfg_list "${config}" catalog operators "${tag}" "${kind}")" || return 1
  [[ -z "${specs}" ]] && specs="latest"
  printf '%s\n' "${specs}" | _validate_items "catalog.operators.${tag}.${kind} entry"
}

status_versions() {
  cfg_keys "$1" status operators "$2" "$3"
}

status_field() {
  cfg_get "$1" status operators "$2" "$3" "$4" "$5"
}

# Rewrite the whole top-level `status` block from leaf rows on stdin.
write_status() {
  local config="$1"
  local parser
  parser="$(config_parser)" || return 1
  if [[ "${parser}" == "python3" ]]; then
    _cfg_py write-status "${config}"
    return
  fi
  local rows line expr path value
  rows="$(cat)"
  yq -i '.status = {}' "${config}"
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    value="${line##*$'\t'}"
    path="$(printf '%s\n' "${line%$'\t'*}" | tr '\t' '\n' | while IFS= read -r k; do
      if [[ ! "${k}" =~ ${_CFG_KEY_RE} ]]; then
        echo "ERROR: invalid status key '${k}'" >&2
        exit 1
      fi
      printf '["%s"]' "${k}"
    done)" || return 1
    V="${value}" yq -i ".status${path} = strenv(V)" "${config}"
  done <<< "${rows}"
}

unit_dir() {
  printf '%s/MANAGE/%s/%s-%s' "$1" "$2" "$3" "$4"
}

# run_python SCRIPT ARGS...  — run a stdlib-only python script with python3 on
# the host, or (when the host has none) in a throwaway python container. Path
# arguments must then live under the repo root, which is mounted at the same
# path inside the container.
run_python() {
  local script="$1"; shift
  if command -v python3 &>/dev/null; then
    python3 -I "${script}" "$@"
  else
    local root
    root="$(cd "${CONFIG_LIB_DIR}/.." && pwd)"
    "${CONTAINER_ENGINE:?container engine not resolved}" run --rm \
      -v "${root}:${root}" -w "${root}" "${MAS_PYTHON_IMAGE}" \
      python -I "${script}" "$@"
  fi
}

# ---------------------------------------------------------------------------
# Per-unit runner
# ---------------------------------------------------------------------------
# A workflow script calls `run_units "${BASH_SOURCE[0]}" MODE "$@"` where MODE is
#   tag     -> one unit per configured operator tag            (step 2)
#   manage  -> one unit per resolved Manage version of each tag (steps 3-4)
#   core    -> one unit per resolved MAS core version of each tag (step 4)
# In the parent invocation it parses `--tag <tag>` and `--version <version>`
# (both repeatable; default: everything), re-executes the script once per unit
# with MAS_CHILD_TAG / MAS_CHILD_KIND / MAS_CHILD_VERSION set, and collects the
# rows each child records with `result KEY VALUE`. Each child runs under its own
# `set -e`, so one failing unit does not stop the others. Afterwards call
# print_run_summary (one column per unit) and finally `exit "${RUN_RC}"`.
# run_units may be called more than once (step 4 runs core, then manage).
#
# In a child invocation run_units returns immediately.
#
# Parent-side globals: RUN_UNITS (space-separated unit ids), RUN_RC (0 = all
# units OK, 1 = at least one failed), RUN_RESULTS_DIR, RUN_SKIPPED (units that
# could not be started, e.g. a tag without resolved versions).

result() {
  [[ -n "${MAS_RESULT_FILE:-}" ]] && printf '%s\t%s\n' "$1" "$2" >> "${MAS_RESULT_FILE}"
  return 0
}

# Extra machine-readable output of a child (step 2 status rows).
result_rows_file() {
  printf '%s' "${MAS_RESULT_FILE%.tsv}.rows"
}

# result_value UNIT KEY -> value recorded by that unit's child run ("" if none).
result_value() {
  local file="${RUN_RESULTS_DIR}/$1.tsv"
  [[ -f "${file}" ]] || return 0
  awk -F'\t' -v k="$2" '$1 == k { v = $2 } END { if (v != "") print v }' "${file}"
}

result_ok() {
  [[ "$(cat "${RUN_RESULTS_DIR}/$1.status" 2>/dev/null)" == "OK" ]]
}

_unit_label() {
  # unit id "tag@kind@version" (or just "tag") -> column label
  local id="$1"
  if [[ "${id}" == *@*@* ]]; then
    local tag="${id%%@*}" rest="${id#*@}"
    printf '%s / %s %s' "${tag}" "${rest%%@*}" "${rest#*@}"
  else
    printf '%s' "${id}"
  fi
}

_print_unit_table() {
  local args=() labels="" unit
  for unit in ${RUN_UNITS}; do
    args+=("${RUN_RESULTS_DIR}/${unit}.all")
    labels="${labels}$(_unit_label "${unit}")"$'\x1f'
  done
  [[ ${#args[@]} -eq 0 ]] && { echo "(nothing to run)"; return 0; }
  awk -F'\t' -v labels="${labels}" '
    BEGIN { split(labels, col, "\x1f") }
    FNR == 1 { ncol++ }
    { if (!($1 in seen)) { seen[$1] = 1; order[++nrow] = $1 }; val[$1, ncol] = $2 }
    END {
      w = length("Metric")
      for (r = 1; r <= nrow; r++) if (length(order[r]) > w) w = length(order[r])
      line = sprintf("| %-" w "s |", "Metric"); sep = "|" sprintf("%" (w + 2) "s", "") "|"
      gsub(/ /, "-", sep)
      for (c = 1; c <= ncol; c++) { line = line " " col[c] " |"; sep = sep "---|" }
      print line; print sep
      for (r = 1; r <= nrow; r++) {
        line = sprintf("| %-" w "s |", order[r])
        for (c = 1; c <= ncol; c++) { v = val[order[r], c]; line = line " " (v == "" ? "—" : v) " |" }
        print line
      }
    }' "${args[@]}"
}

run_units() {
  local script="$1" mode="$2"; shift 2
  [[ -n "${MAS_CHILD_TAG:-}" ]] && return 0

  local req_tags=" " req_versions=" " all_tags tag
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag)
        [[ $# -ge 2 ]] || { echo "ERROR: --tag needs a value" >&2; exit 2; }
        req_tags="${req_tags}$2 "; shift 2 ;;
      --tag=*)
        req_tags="${req_tags}${1#--tag=} "; shift ;;
      --version)
        [[ $# -ge 2 ]] || { echo "ERROR: --version needs a value" >&2; exit 2; }
        req_versions="${req_versions}$2 "; shift 2 ;;
      --version=*)
        req_versions="${req_versions}${1#--version=} "; shift ;;
      --list-versions)
        # Handled by the calling script before run_units; ignore here.
        shift ;;
      -h | --help)
        echo "Usage: $(basename "${script}") [--tag <operatorTag>]... [--version <version>]..."
        echo "  Runs for every configured operator tag (catalog.operators in config.yaml)"
        [[ "${mode}" != "tag" ]] && echo "  and every resolved ${mode} version in status.operators.<tag>.${mode}"
        echo "  — or only for the given tag(s) / version(s)."
        exit 0 ;;
      *)
        echo "ERROR: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
  done
  if [[ "${mode}" == "tag" && "${req_versions}" != " " ]]; then
    echo "ERROR: --version does not apply to this step." >&2
    exit 2
  fi

  all_tags="$(operator_tags "${CONFIG}")" || exit 1
  if [[ -z "${all_tags}" ]]; then
    echo "ERROR: no operator tags configured (catalog.operators or catalog.operatorTag in ${CONFIG})." >&2
    exit 1
  fi

  local tags=""
  if [[ "${req_tags}" == " " ]]; then
    tags="$(printf '%s ' ${all_tags})"
  else
    for tag in ${req_tags}; do
      if ! printf '%s\n' "${all_tags}" | grep -qxF -- "${tag}"; then
        echo "ERROR: --tag '${tag}' is not configured in ${CONFIG}." >&2
        echo "       Configured tags: $(printf '%s ' ${all_tags})" >&2
        exit 2
      fi
      tags="${tags}${tag} "
    done
  fi

  # Build the unit list.
  RUN_UNITS=""
  RUN_SKIPPED=""
  local version versions matched=" "
  for tag in ${tags}; do
    if [[ "${mode}" == "tag" ]]; then
      RUN_UNITS="${RUN_UNITS}${tag} "
      continue
    fi
    versions="$(status_versions "${CONFIG}" "${tag}" "${mode}")"
    if [[ -z "${versions}" ]]; then
      local skipped_specs
      skipped_specs="$(cfg_get "${CONFIG}" status operators "${tag}" skipped "${mode}")"
      if [[ -n "${skipped_specs}" ]]; then
        # Intentional: e.g. core <= 9.0 ships no Graphite. Not a failure.
        echo "NOTE: ${tag}: no ${mode} versions to extract (${skipped_specs} skipped by step 2)."
      elif [[ -n "$(cfg_get "${CONFIG}" status operators "${tag}" catalogImage)" ]]; then
        RUN_SKIPPED="${RUN_SKIPPED}${tag} "
        echo "WARNING: step 2 resolved no ${mode} versions for ${tag} — see its errors (scripts/mas-manage-resolve-image.sh --tag ${tag})." >&2
      else
        RUN_SKIPPED="${RUN_SKIPPED}${tag} "
        echo "WARNING: ${tag} is not in status.operators — run scripts/mas-manage-resolve-image.sh first." >&2
      fi
      continue
    fi
    for version in ${versions}; do
      if [[ "${req_versions}" != " " && "${req_versions}" != *" ${version} "* ]]; then
        continue
      fi
      matched="${matched}${version} "
      RUN_UNITS="${RUN_UNITS}${tag}@${mode}@${version} "
    done
  done
  for version in ${req_versions}; do
    if [[ "${matched}" != *" ${version} "* ]]; then
      echo "WARNING: --version ${version} matches no resolved ${mode} version of the selected tag(s)." >&2
    fi
  done

  RUN_RESULTS_DIR="${RUN_RESULTS_DIR:-$(mktemp -d)}"
  # shellcheck disable=SC2064
  trap "rm -rf '${RUN_RESULTS_DIR}'" EXIT
  RUN_RC="${RUN_RC:-0}"
  [[ -n "${RUN_SKIPPED}" ]] && RUN_RC=1

  local total=0 i=0 rc unit u_tag u_kind u_version
  for unit in ${RUN_UNITS}; do total=$((total + 1)); done
  for unit in ${RUN_UNITS}; do
    i=$((i + 1))
    u_tag="${unit%%@*}"; u_kind=""; u_version=""
    if [[ "${unit}" == *@*@* ]]; then
      u_kind="${unit#*@}"; u_kind="${u_kind%%@*}"; u_version="${unit##*@}"
    fi
    echo ""
    echo "=== [${i}/${total}] $(_unit_label "${unit}") ==="
    : > "${RUN_RESULTS_DIR}/${unit}.tsv"
    rc=0
    MAS_CHILD_TAG="${u_tag}" MAS_CHILD_KIND="${u_kind}" MAS_CHILD_VERSION="${u_version}" \
      MAS_RESULT_FILE="${RUN_RESULTS_DIR}/${unit}.tsv" \
      "${BASH:-bash}" "${script}" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
      echo "OK" > "${RUN_RESULTS_DIR}/${unit}.status"
    else
      echo "FAILED (exit ${rc})" > "${RUN_RESULTS_DIR}/${unit}.status"
      echo "ERROR: $(_unit_label "${unit}") failed (exit ${rc}); continuing with the rest." >&2
      RUN_RC=1
    fi
    { printf 'Status\t%s\n' "$(cat "${RUN_RESULTS_DIR}/${unit}.status")"
      cat "${RUN_RESULTS_DIR}/${unit}.tsv"; } > "${RUN_RESULTS_DIR}/${unit}.all"
  done
}

# Print the combined summary table for the last run_units call.
print_run_summary() {
  echo ""
  _print_unit_table
}
