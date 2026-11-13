#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# config-lib.sh — Shared config.yaml helpers + per-operator-tag runner
# ---------------------------------------------------------------------------
# Sourced by the workflow scripts. Provides:
#   cfg_get   CONFIG KEY...          scalar value ("" when absent/null)
#   cfg_list  CONFIG KEY...          one item per line (list, or comma-split scalar)
#   cfg_bool  CONFIG DEFAULT KEY...  "true" | "false" (errors on other values)
#   operator_tags CONFIG             catalog.operatorTag as a de-duplicated list
#   status_image  CONFIG TAG FIELD   status.operators.<TAG>.<FIELD>
#   write_status_operators CONFIG    rewrite status.operators from TSV on stdin
#                                    (tag<TAB>catalogImage<TAB>manageadmin<TAB>graphite)
#   operator_dir REPO_ROOT TAG       MANAGE/<TAG> output folder for a tag
#   run_per_tag SCRIPT ARGS...       run SCRIPT once per operator tag (see below)
#   result KEY VALUE                 record a summary row (inside a per-tag run)
#
# Keys are passed as separate arguments (cfg_get "$CONFIG" masManage database host)
# so operator tags containing dots are handled safely.
#
# Parsing uses the mikefarah `yq` binary when present, else python3 with the
# bundled scripts/config_yaml.py. One of the two is required (checked by
# scripts/prerequisites.sh).
#
# Bash 3.2 compatible (stock macOS): no associative arrays or mapfile.
# ---------------------------------------------------------------------------

CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# OCI tag charset; also keeps generated yq expressions and paths safe.
_CFG_KEY_RE='^[A-Za-z0-9._-]+$'

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

cfg_get() {
  local config="$1"; shift
  local parser out path
  parser="$(config_parser)" || return 1
  if [[ "${parser}" == "yq" ]]; then
    path="$(_cfg_yq_path "$@")" || return 1
    out="$(yq "${path} | select(tag != \"!!map\" and tag != \"!!seq\")" "${config}" 2>/dev/null || true)"
  else
    out="$(python3 -I "${CONFIG_LIB_DIR}/config_yaml.py" get "${config}" "$@")" || return 1
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
    python3 -I "${CONFIG_LIB_DIR}/config_yaml.py" list "${config}" "$@"
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
    "")                 printf '%s' "${default}" ;;
    true | yes | on | 1)  printf 'true' ;;
    false | no | off | 0) printf 'false' ;;
    *)
      local IFS=.
      echo "ERROR: $*='${raw}' in ${config} is not a boolean (use true or false)." >&2
      return 1
      ;;
  esac
}

# catalog.operatorTag as a list: accepts a scalar, a flow list or a block list.
# Duplicates are dropped (first occurrence wins); invalid tags are an error.
operator_tags() {
  local config="$1" tag seen=" "
  local tags
  tags="$(cfg_list "${config}" catalog operatorTag)" || return 1
  while IFS= read -r tag; do
    [[ -z "${tag}" ]] && continue
    if [[ ! "${tag}" =~ ${_CFG_KEY_RE} ]]; then
      echo "ERROR: invalid catalog.operatorTag entry '${tag}' in ${config}" >&2
      return 1
    fi
    [[ "${seen}" == *" ${tag} "* ]] && continue
    seen="${seen}${tag} "
    printf '%s\n' "${tag}"
  done <<< "${tags}"
}

status_image() {
  cfg_get "$1" status operators "$2" "$3"
}

write_status_operators() {
  local config="$1"
  local parser
  parser="$(config_parser)" || return 1
  if [[ "${parser}" == "python3" ]]; then
    python3 -I "${CONFIG_LIB_DIR}/config_yaml.py" write-status "${config}"
    return
  fi
  local tag catalog manageadmin graphite
  yq -i '.status = {"operators": {}}' "${config}"
  while IFS=$'\t' read -r tag catalog manageadmin graphite; do
    [[ -z "${tag}" ]] && continue
    T="${tag}" C="${catalog}" M="${manageadmin}" G="${graphite}" yq -i '
      .status.operators[strenv(T)].catalogImage = strenv(C) |
      .status.operators[strenv(T)].manageadmin  = strenv(M) |
      .status.operators[strenv(T)].graphite     = strenv(G)' "${config}"
  done
}

operator_dir() {
  printf '%s/MANAGE/%s' "$1" "$2"
}

# ---------------------------------------------------------------------------
# Per-tag runner
# ---------------------------------------------------------------------------
# A workflow script calls `run_per_tag "${BASH_SOURCE[0]}" "$@"` at the top.
# In the parent invocation it parses `--tag <tag>` (repeatable; default: every
# tag in catalog.operatorTag), re-executes the script once per tag with
# MAS_CHILD_TAG set, and prints a combined summary table (one column per tag).
# Each child runs under its own `set -e`, so one failing tag does not stop the
# others. After the loop, the parent may post-process (step 2 writes
# status.operators) using result_value; finally it should `exit "${RUN_RC}"`.
#
# In the child invocation run_per_tag returns immediately; the script reads
# MAS_CHILD_TAG and records summary rows with `result KEY VALUE`.
#
# Parent-side globals set: RUN_TAGS (space-separated, in order), RUN_RC
# (0 = all tags OK, 1 = at least one failed), RUN_RESULTS_DIR.

result() {
  [[ -n "${MAS_RESULT_FILE:-}" ]] && printf '%s\t%s\n' "$1" "$2" >> "${MAS_RESULT_FILE}"
  return 0
}

# result_value TAG KEY -> value recorded by that tag's child run ("" if none).
result_value() {
  local file="${RUN_RESULTS_DIR}/$1.tsv"
  [[ -f "${file}" ]] || return 0
  awk -F'\t' -v k="$2" '$1 == k { v = $2 } END { if (v != "") print v }' "${file}"
}

# result_ok TAG -> success if that tag's child run exited 0.
result_ok() {
  [[ "$(cat "${RUN_RESULTS_DIR}/$1.status" 2>/dev/null)" == "OK" ]]
}

_print_tag_table() {
  local args=() tag
  for tag in ${RUN_TAGS}; do
    args+=("${RUN_RESULTS_DIR}/${tag}.all")
  done
  awk -F'\t' '
    FNR == 1 { ncol++; split(FILENAME, p, "/"); col[ncol] = p[length(p)]; sub(/\.all$/, "", col[ncol]) }
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

run_per_tag() {
  local script="$1"; shift
  [[ -n "${MAS_CHILD_TAG:-}" ]] && return 0

  local requested=" " all_tags tag
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag)
        [[ $# -ge 2 ]] || { echo "ERROR: --tag needs a value" >&2; exit 2; }
        requested="${requested}$2 "; shift 2 ;;
      --tag=*)
        requested="${requested}${1#--tag=} "; shift ;;
      -h | --help)
        echo "Usage: $(basename "${script}") [--tag <operatorTag>]..."
        echo "  Runs once per tag in catalog.operatorTag (config.yaml), or only for the given tag(s)."
        exit 0 ;;
      *)
        echo "ERROR: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
  done

  all_tags="$(operator_tags "${CONFIG}")" || exit 1
  if [[ -z "${all_tags}" ]]; then
    echo "ERROR: catalog.operatorTag in ${CONFIG} is empty." >&2
    exit 1
  fi

  RUN_TAGS=""
  if [[ "${requested}" == " " ]]; then
    RUN_TAGS="$(printf '%s ' ${all_tags})"
  else
    for tag in ${requested}; do
      if ! printf '%s\n' "${all_tags}" | grep -qxF -- "${tag}"; then
        echo "ERROR: --tag '${tag}' is not listed in catalog.operatorTag of ${CONFIG}." >&2
        echo "       Configured tags: $(printf '%s ' ${all_tags})" >&2
        exit 2
      fi
      RUN_TAGS="${RUN_TAGS}${tag} "
    done
  fi

  RUN_RESULTS_DIR="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${RUN_RESULTS_DIR}'" EXIT
  RUN_RC=0

  local total=0 i=0 rc
  for tag in ${RUN_TAGS}; do total=$((total + 1)); done
  for tag in ${RUN_TAGS}; do
    i=$((i + 1))
    echo ""
    echo "=== [${i}/${total}] Operator tag: ${tag} ==="
    : > "${RUN_RESULTS_DIR}/${tag}.tsv"
    rc=0
    MAS_CHILD_TAG="${tag}" MAS_RESULT_FILE="${RUN_RESULTS_DIR}/${tag}.tsv" \
      "${BASH:-bash}" "${script}" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
      echo "OK" > "${RUN_RESULTS_DIR}/${tag}.status"
    else
      echo "FAILED (exit ${rc})" > "${RUN_RESULTS_DIR}/${tag}.status"
      echo "ERROR: operator tag ${tag} failed (exit ${rc}); continuing with the remaining tags." >&2
      RUN_RC=1
    fi
    { printf 'Status\t%s\n' "$(cat "${RUN_RESULTS_DIR}/${tag}.status")"
      cat "${RUN_RESULTS_DIR}/${tag}.tsv"; } > "${RUN_RESULTS_DIR}/${tag}.all"
  done
}

# Print the combined per-tag summary table (call after run_per_tag + any
# post-processing).
print_run_summary() {
  echo ""
  _print_tag_table
}
