#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# container-runtime.sh — Resolve the container engine (docker | podman)
# ---------------------------------------------------------------------------
# Sourced by every workflow script. Reads container.engine from config.yaml
# (default: docker) and echoes the resolved engine command after checking it is
# on PATH. Docker and Podman share the CLI surface these scripts use
# (pull / create / cp / run / inspect / --platform / --env-file / -v), so
# callers simply use "${CONTAINER_ENGINE}" wherever they previously said docker.
#
# Usage:
#   source "${SCRIPT_DIR}/container-runtime.sh"
#   CONTAINER_ENGINE="$(resolve_container_engine "${CONFIG}")" || exit 1
# ---------------------------------------------------------------------------

# Parse container.engine from config.yaml. Prints "docker" when the key is
# absent/empty. Mirrors the yq -> python3 -> grep fallback used elsewhere.
# Only the `container:` block is inspected, so this stays robust even if other
# parts of config.yaml are momentarily malformed.
# Normalize a raw value: lowercase, strip whitespace/quotes, "null" -> "".
_normalize_engine_value() {
  local v
  v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  v="${v//\"/}"
  v="${v//\'/}"
  [[ "${v}" == "null" ]] && v=""
  printf '%s' "${v}"
}

# Read only the container: block via a line-scoped scan (python3 -> grep). This
# is deliberately independent of a whole-file YAML parse, so the engine choice
# is honored even if another part of config.yaml is momentarily malformed.
_parse_container_engine_block() {
  local config="$1"
  if command -v python3 &>/dev/null; then
    python3 - "${config}" <<'EOF'
import sys, re
try:
    with open(sys.argv[1]) as f:
        lines = f.readlines()
except OSError:
    sys.exit(0)
in_container = False
for line in lines:
    if re.match(r'^container\s*:', line):
        in_container = True
        continue
    if in_container:
        # Left the container: block at the next top-level key.
        if re.match(r'^\S', line):
            break
        m = re.match(r'^\s+engine:\s*(.+)$', line)
        if m:
            print(re.sub(r'\s+#.*$', '', m.group(1)).strip())
            break
EOF
  else
    grep -A5 '^container:' "${config}" 2>/dev/null \
      | grep -E '^[[:space:]]+engine:' \
      | head -1 \
      | awk -F': ' '{print $2}' \
      | awk '{print $1}'
  fi
}

_parse_container_engine() {
  local config="$1"
  local val=""
  if [[ -z "${config}" || ! -f "${config}" ]]; then
    printf 'docker'
    return 0
  fi
  # Prefer yq (whole-file parse) when present, but if it is absent OR cannot
  # read the file (e.g. a malformed value elsewhere) fall back to the
  # block-scoped scan so container.engine is still honored — never silently
  # defaulting to docker when podman was actually requested.
  if command -v yq &>/dev/null; then
    val="$(_normalize_engine_value "$(yq '.container.engine' "${config}" 2>/dev/null || true)")"
  fi
  if [[ -z "${val}" ]]; then
    val="$(_normalize_engine_value "$(_parse_container_engine_block "${config}")")"
  fi
  printf '%s' "${val:-docker}"
}

# Echo the configured engine name (docker|podman), validating the value.
# Does NOT check PATH. On an unsupported value: message to stderr, returns 1.
container_engine_name() {
  local config="${1:-}"
  local engine
  engine="$(_parse_container_engine "${config}")"
  case "${engine}" in
    docker | podman)
      printf '%s' "${engine}"
      ;;
    *)
      echo "ERROR: unsupported container.engine '${engine}' in ${config}." >&2
      echo "       Supported values: docker, podman." >&2
      return 1
      ;;
  esac
}

# Echo the engine name after confirming it is on PATH. On failure (bad value or
# engine missing): message to stderr, returns 1.
resolve_container_engine() {
  local config="${1:-}"
  local engine
  engine="$(container_engine_name "${config}")" || return 1
  if ! command -v "${engine}" &>/dev/null; then
    echo "ERROR: container engine '${engine}' is not on PATH." >&2
    echo "       Install it, or set container.engine in ${config} to an available engine (docker | podman)." >&2
    return 1
  fi
  printf '%s' "${engine}"
}
