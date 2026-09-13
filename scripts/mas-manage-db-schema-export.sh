#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# mas-manage-db-schema-export.sh — Export DB schema to MANAGE/DBSCHEMA/
# ---------------------------------------------------------------------------
# Engine-independent: the target engine is chosen by masManage.database.type
# in config.yaml. Supported out of the box:
#   - mssql  (Microsoft SQL Server)  driver: pymssql
#   - db2    (IBM DB2)               driver: ibm_db / ibm_db_sa
#   - oracle (Oracle)               driver: oracledb (thin mode, no client)
# These are the engines IBM Maximo / MAS Manage runs on. Adding another engine
# is a one-line entry in the case statement below plus a driver package.
#
# The schema is reflected with SQLAlchemy inside a short-lived python:3-slim
# Docker container (removed on completion), so the host needs only Docker —
# no local database client or SQL tooling required.
#
# masManage.schemaTables in config.yaml selects which tables' schema (DDL) is
# exported: "*" (or the key absent) exports every table and view, while a list
# such as WORKORDER,ASSET,LOCATIONS exports DDL only for those objects.
#
# In addition to the DDL, the full row DATA of the tables listed under
# masManage.dataTables in config.yaml is exported to
# MANAGE/DBSCHEMA/data/<TABLE>.csv (one CSV per table, named after the table).
# CSV is used because it is the most compact and stream-friendly format for
# large tables (potentially millions of rows) and is read natively by
# pandas / duckdb / awk and by AI agents. SQL NULL is written as an empty field.
#
# Prerequisites:
#   - Docker
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG="${REPO_ROOT}/config.yaml"
DBSCHEMA_DIR="${REPO_ROOT}/MANAGE/DBSCHEMA"
TABLES_DIR="${DBSCHEMA_DIR}/tables"
VIEWS_DIR="${DBSCHEMA_DIR}/views"
DATA_DIR="${DBSCHEMA_DIR}/data"

# Pinned to the bookworm (Debian 12) variant on purpose. The default
# `python:3.12-slim` now tracks Debian trixie, whose apt verifies repository
# signatures with Sequoia (sqv); that fails ("InRelease: No good signature")
# when the container runs under amd64 emulation — which the DB2 path always does
# on ARM hosts (--platform linux/amd64). bookworm's classic gpgv works fine
# there, so the libxml2 install the DB2 driver needs succeeds.
PYTHON_IMAGE="python:3.12-slim-bookworm"

# Container engine (docker | podman) chosen by container.engine in config.yaml.
# shellcheck source=scripts/container-runtime.sh
source "${SCRIPT_DIR}/container-runtime.sh"
CONTAINER_ENGINE="$(resolve_container_engine "${CONFIG}")" || exit 1

# ---------------------------------------------------------------------------
# 1. Parse DB connection values from config.yaml
# ---------------------------------------------------------------------------
parse_value() {
  local key="$1"
  if command -v yq &>/dev/null; then
    yq "${key}" "${CONFIG}"
  elif command -v python3 &>/dev/null; then
    python3 - "${CONFIG}" "${key}" <<'EOF'
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
leaf = sys.argv[2].split('.')[-1]
match = re.search(r'^\s*' + re.escape(leaf) + r':\s*(.+)$', content, re.MULTILINE)
if match:
    print(match.group(1).strip())
else:
    sys.exit(f"ERROR: could not parse {sys.argv[2]} from config.yaml")
EOF
  else
    grep -E "^\s*${key##*.}:" "${CONFIG}" \
      | awk -F': ' '{print $2}' \
      | awk '{print $1}'
  fi
}

# Parse a table selector (e.g. masManage.schemaTables or masManage.dataTables)
# into a comma-separated string. Accepts a scalar ("*" or a comma-separated
# list), a YAML flow sequence ([A, B, C]) or a YAML block list; "" when the key
# is absent/empty. Callers decide what an empty result means (schemaTables ->
# all; dataTables -> none).
#   $1 = yq-style path, e.g. .masManage.dataTables
parse_selector() {
  local path="$1"
  local leaf="${path##*.}"
  local out=""
  if command -v yq &>/dev/null; then
    out="$(yq "[${path}] | flatten | join(\",\")" "${CONFIG}" 2>/dev/null || true)"
  elif command -v python3 &>/dev/null; then
    out="$(python3 - "${CONFIG}" "${leaf}" <<'EOF'
import sys, re
with open(sys.argv[1]) as f:
    lines = f.readlines()
key = sys.argv[2]
val, items, in_list = None, [], False
for line in lines:
    m = re.match(r'^\s*' + re.escape(key) + r'\s*:\s*(.*)$', line)
    if m and not in_list and val is None and not items:
        inline = re.sub(r'\s+#.*$', '', m.group(1)).strip()
        if inline.startswith('[') and inline.endswith(']'):
            # YAML flow sequence, e.g. [A, B, C]
            val = ','.join(p.strip().strip('"').strip("'")
                           for p in inline[1:-1].split(',') if p.strip())
            break
        inline = inline.strip('"').strip("'")
        if inline:
            val = inline
            break
        in_list = True
        continue
    if in_list:
        lm = re.match(r'^\s*-\s*(.+?)\s*$', line)
        if lm:
            items.append(lm.group(1).strip().strip('"').strip("'"))
        elif line.strip() == '':
            continue
        else:
            break
print(val if val is not None else ','.join(items))
EOF
)"
  else
    # Degraded fallback (no yq/python3): handles scalar, comma list and flow
    # sequence on one line; strips quotes, brackets and spaces. Block lists
    # need yq or python3.
    out="$(grep -E "^[[:space:]]*${leaf}:" "${CONFIG}" | head -1 \
      | sed -E "s/^[[:space:]]*${leaf}:[[:space:]]*//; s/[[:space:]]*#.*$//" \
      | tr -d "\042\047[] " || true)"
  fi
  if [[ "${out}" == "null" ]]; then
    out=""
  fi
  printf '%s' "${out}"
}

DB_TYPE_RAW="$(parse_value '.masManage.database.type')"
DB_HOST="$(parse_value '.masManage.database.host')"
DB_PORT="$(parse_value '.masManage.database.port')"
DB_NAME="$(parse_value '.masManage.database.name')"
DB_USER="$(parse_value '.masManage.database.username')"
DB_PASS="$(parse_value '.masManage.database.password')"
DB_SCHEMA="$(parse_value '.masManage.database.schema')"
DATA_TABLES="$(parse_selector '.masManage.dataTables')"
SCHEMA_TABLES="$(parse_selector '.masManage.schemaTables')"
# schemaTables defaults to all tables when unset; dataTables defaults to none.
if [[ -z "${SCHEMA_TABLES}" ]]; then SCHEMA_TABLES="*"; fi

if [[ -z "${DB_TYPE_RAW}" || -z "${DB_HOST}" || -z "${DB_PORT}" || -z "${DB_NAME}" || -z "${DB_USER}" || -z "${DB_PASS}" || -z "${DB_SCHEMA}" ]]; then
  echo "ERROR: could not read masManage.database fields (type, host, port, name, username, password, schema) from ${CONFIG}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Map engine type -> SQLAlchemy driver + pip packages
# ---------------------------------------------------------------------------
DB_TYPE="$(echo "${DB_TYPE_RAW}" | tr '[:upper:]' '[:lower:]')"
case "${DB_TYPE}" in
  mssql|sqlserver|mssqlserver) DB_TYPE="mssql";  PIP_PKGS="pymssql";          ENGINE_LABEL="SQL Server" ;;
  db2|ibmdb2|ibm_db2)          DB_TYPE="db2";    PIP_PKGS="ibm_db ibm_db_sa"; ENGINE_LABEL="IBM DB2" ;;
  oracle|ora)                  DB_TYPE="oracle"; PIP_PKGS="oracledb";         ENGINE_LABEL="Oracle" ;;
  *)
    echo "ERROR: unsupported masManage.database.type '${DB_TYPE_RAW}'." >&2
    echo "       Supported: mssql (SQL Server), db2 (IBM DB2), oracle (Oracle)." >&2
    exit 1
    ;;
esac

echo "Engine:   ${ENGINE_LABEL} (${DB_TYPE})"
echo "Database: ${DB_HOST}:${DB_PORT}/${DB_NAME} (schema: ${DB_SCHEMA})"
if [[ "${SCHEMA_TABLES}" == "*" ]]; then
  echo "Schema scope: all tables"
else
  echo "Schema scope: ${SCHEMA_TABLES}"
fi

# ---------------------------------------------------------------------------
# 3. Prepare output directories (clean previously exported .sql files)
# ---------------------------------------------------------------------------
mkdir -p "${TABLES_DIR}" "${VIEWS_DIR}"
echo "Cleaning up existing .sql files ..."
rm -f "${TABLES_DIR}"/*.sql "${VIEWS_DIR}"/*.sql 2>/dev/null || true

if [[ -n "${DATA_TABLES}" ]]; then
  mkdir -p "${DATA_DIR}"
  if [[ "${DATA_TABLES}" == "*" ]]; then
    echo "Data export requested for: all tables"
  else
    echo "Data export requested for table(s): ${DATA_TABLES}"
  fi
  echo "Cleaning up existing .csv files ..."
  rm -f "${DATA_DIR}"/*.csv 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. Write the reflection script and a locked-down env file (temp, mounted in)
# ---------------------------------------------------------------------------
# Credentials travel via a 0600 env file mounted into the container, never on
# the engine command line — so they do not appear in the host process list.
# The temp files are created under the repo's (gitignored) tmp/ dir rather than
# /tmp: Podman on macOS only bind-mounts paths inside the machine's shared
# mounts (the user's home dir), and /tmp is not shared there. Docker mounts
# these paths just as happily, so this works for both engines on every host.
TMP_MOUNT_DIR="${REPO_ROOT}/tmp"
mkdir -p "${TMP_MOUNT_DIR}"
PY_FILE="$(mktemp "${TMP_MOUNT_DIR}/mas-reflect.XXXXXX.py")"
ENV_FILE="$(mktemp "${TMP_MOUNT_DIR}/mas-dbenv.XXXXXX.env")"
trap 'rm -f "${PY_FILE}" "${ENV_FILE}"' EXIT
chmod 600 "${ENV_FILE}"

cat > "${ENV_FILE}" <<EOF
DB_TYPE=${DB_TYPE}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
DB_SCHEMA=${DB_SCHEMA}
DATA_TABLES=${DATA_TABLES}
SCHEMA_TABLES=${SCHEMA_TABLES}
EOF

cat > "${PY_FILE}" <<'PYEOF'
import csv
import os
import re
import sys

from sqlalchemy import MetaData, Table, create_engine, inspect, select
from sqlalchemy.engine import URL
from sqlalchemy.schema import CreateIndex, CreateTable

DRIVERS = {
    "mssql":  "mssql+pymssql",
    "db2":    "db2+ibm_db",
    "oracle": "oracle+oracledb",
}

db_type = os.environ["DB_TYPE"].strip().lower()
host    = os.environ["DB_HOST"].strip()
port    = os.environ.get("DB_PORT", "").strip()
name    = os.environ["DB_NAME"].strip()
user    = os.environ["DB_USER"].strip()
pw      = os.environ["DB_PASS"]
schema  = os.environ.get("DB_SCHEMA", "").strip() or None
out     = os.environ.get("OUT_DIR", "/out")

drivername = DRIVERS[db_type]
port_int = int(port) if port else None

# DB2 and Oracle fold unquoted identifiers to upper case and store catalog
# schema names in upper case; Maximo uses the upper-case schema there.
if db_type in ("db2", "oracle") and schema:
    schema = schema.upper()

if db_type == "oracle":
    url = URL.create(drivername, username=user, password=pw,
                     host=host, port=port_int, query={"service_name": name})
else:
    url = URL.create(drivername, username=user, password=pw,
                     host=host, port=port_int, database=name)

engine = create_engine(url)

# Fail fast with a clear message if the connection cannot be established.
try:
    with engine.connect():
        pass
except Exception as exc:
    sys.exit(f"ERROR: could not connect to {db_type} at {host}:{port}: {exc}")

tables_dir = os.path.join(out, "tables")
views_dir  = os.path.join(out, "views")
os.makedirs(tables_dir, exist_ok=True)
os.makedirs(views_dir, exist_ok=True)


def safe(n):
    return re.sub(r"[^A-Za-z0-9._-]", "_", n)


insp = inspect(engine)

# Resolve the schema: honor the configured one, but fall back to the driver's
# default schema if it turns up empty (e.g. SQL Server 'dbo' vs 'maximo').
resolved_schema = schema
table_names = []
for candidate in ([schema, None] if schema else [None]):
    try:
        found = insp.get_table_names(schema=candidate)
    except Exception:
        found = []
    if found:
        table_names = found
        resolved_schema = candidate
        break

if resolved_schema != schema:
    print(f"WARNING: schema '{schema}' had no tables; using default schema instead.", flush=True)

# Keep the full, unfiltered table list — the data export ("*") uses it even
# when the schema DDL export is narrowed by schemaTables.
all_table_names = list(table_names)

# Optional schema-export filter (config.masManage.schemaTables):
# "*" / empty -> export every table and view; otherwise export DDL only for the
# named tables/views (matched case-insensitively). Names matching neither a
# table nor a view are reported after the view list is known.
schema_filter_raw = os.environ.get("SCHEMA_TABLES", "*").strip().strip("[]").strip()
wanted = None if schema_filter_raw in ("", "*") else \
    {n.strip().strip('"').strip("'").lower()
     for n in schema_filter_raw.split(",") if n.strip()}
matched = set()

if wanted is not None:
    avail_t = {t.lower(): t for t in table_names}
    table_names = [avail_t[w] for w in sorted(wanted) if w in avail_t]
    matched |= {w for w in wanted if w in avail_t}

print(f"Reflecting {len(table_names)} tables from schema "
      f"'{resolved_schema or '(default)'}' ...", flush=True)

tcount = 0
for tname in sorted(table_names):
    md = MetaData()
    try:
        table = Table(tname, md, autoload_with=engine, schema=resolved_schema)
    except Exception as exc:
        print(f"WARNING: table {tname} skipped ({exc})", flush=True)
        continue
    if len(table.columns) == 0:
        print(f"WARNING: table {tname} has no reflectable columns; skipped", flush=True)
        continue

    parts = [str(CreateTable(table).compile(engine)).strip() + ";"]
    for idx in sorted(table.indexes, key=lambda i: (i.name or "")):
        try:
            parts.append(str(CreateIndex(idx).compile(engine)).strip() + ";")
        except Exception as exc:
            parts.append(f"-- index {idx.name} skipped: {exc}")

    with open(os.path.join(tables_dir, safe(tname) + ".sql"), "w") as fh:
        fh.write("\n\n".join(parts) + "\n")
    tcount += 1

# Views
vcount = 0
try:
    view_names = insp.get_view_names(schema=resolved_schema)
except Exception as exc:
    view_names = []
    print(f"WARNING: could not list views: {exc}", flush=True)

if wanted is not None:
    avail_v = {v.lower(): v for v in view_names}
    view_names = [avail_v[w] for w in sorted(wanted) if w in avail_v]
    matched |= {w for w in wanted if w in avail_v}
    for w in sorted(wanted - matched):
        print(f"WARNING: schema object '{w}' not found among tables or views in "
              f"schema '{resolved_schema or '(default)'}'; skipped", flush=True)

for vname in sorted(view_names):
    try:
        vdef = insp.get_view_definition(vname, schema=resolved_schema)
    except NotImplementedError:
        print(f"WARNING: view reflection unsupported for {db_type}; skipping views", flush=True)
        break
    except Exception as exc:
        print(f"WARNING: view {vname} skipped ({exc})", flush=True)
        continue
    if not vdef:
        continue
    body = vdef.strip()
    if not re.match(r"(?is)^\s*create\s+", body):
        body = f"CREATE VIEW {vname} AS\n{body}"
    with open(os.path.join(views_dir, safe(vname) + ".sql"), "w") as fh:
        fh.write(body.rstrip().rstrip(";") + ";\n")
    vcount += 1

# ---------------------------------------------------------------------------
# Data export — dump full row contents of the tables selected by
# config.masManage.dataTables to CSV (one file per table, named after the
# table). The selector accepts "*" (all tables), a comma-separated list, or a
# YAML list; empty/absent means no data export. CSV keeps large exports compact
# and stream-friendly; SQL NULL is written as an empty field. Rows are streamed
# so million-row tables do not have to be held in memory.
# ---------------------------------------------------------------------------
data_raw = os.environ.get("DATA_TABLES", "").strip().strip("[]")
requested_raw = [t.strip().strip('"').strip("'") for t in data_raw.split(",") if t.strip()]
data_all = "*" in requested_raw
requested = list(all_table_names) if data_all else requested_raw

dcount = 0
drows = 0
if requested:
    data_dir = os.path.join(out, "data")
    os.makedirs(data_dir, exist_ok=True)

    def reflect_one(nm):
        # Engines differ on identifier case; try as-given, then upper/lower.
        tried = []
        for cand in (nm, nm.upper(), nm.lower()):
            if cand in tried:
                continue
            tried.append(cand)
            try:
                return Table(cand, MetaData(), autoload_with=engine,
                             schema=resolved_schema)
            except Exception:
                continue
        return None

    def to_cell(v):
        if v is None:
            return ""  # SQL NULL -> empty field
        if isinstance(v, (bytes, bytearray, memoryview)):
            return bytes(v).hex()
        return v  # numbers / Decimal / datetime / bool are str()-ified by csv

    def dump(tbl, path, stream):
        rows = 0
        opts = {"stream_results": True, "yield_per": 10000} if stream else {}
        conn = engine.connect().execution_options(**opts)
        try:
            result = conn.execute(select(tbl))
            with open(path, "w", newline="", encoding="utf-8") as fh:
                writer = csv.writer(fh)
                writer.writerow(list(result.keys()))
                for row in result:
                    writer.writerow([to_cell(v) for v in row])
                    rows += 1
        finally:
            conn.close()
        return rows

    if data_all:
        print(f"Exporting data for all {len(requested)} tables", flush=True)
    else:
        print(f"Exporting data for {len(requested)} table(s): "
              f"{', '.join(requested)}", flush=True)
    for req in requested:
        tbl = reflect_one(req)
        if tbl is None:
            print(f"WARNING: data table '{req}' not found in schema "
                  f"'{resolved_schema or '(default)'}'; skipped", flush=True)
            continue
        fname = safe(tbl.name) + ".csv"
        path = os.path.join(data_dir, fname)
        try:
            rows = dump(tbl, path, stream=True)
        except Exception as exc:
            print(f"WARNING: streaming export for '{tbl.name}' failed ({exc}); "
                  f"retrying buffered", flush=True)
            try:
                rows = dump(tbl, path, stream=False)
            except Exception as exc2:
                print(f"WARNING: data export for '{tbl.name}' failed ({exc2})",
                      flush=True)
                continue
        print(f"Data exported: {tbl.name} -> {rows} rows -> data/{fname}",
              flush=True)
        dcount += 1
        drows += rows

print(f"RESULT tables={tcount} views={vcount} datatables={dcount} datarows={drows}",
      flush=True)
PYEOF

# ---------------------------------------------------------------------------
# 5. Reflect the schema inside a short-lived python container
# ---------------------------------------------------------------------------
echo "Reflecting schema in a ${PYTHON_IMAGE} container (removed on completion) ..."

PRE_INSTALL=""
PLATFORM_FLAG=""
if [[ "${DB_TYPE}" == "db2" ]]; then
  # ibm_db's bundled CLI driver needs libxml2 present at runtime.
  PRE_INSTALL="apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends libxml2 >/dev/null;"
  # ibm_db ships no aarch64 build, so it fails to install on ARM hosts
  # (e.g. Apple Silicon). Force amd64 so the x86_64 driver installs under
  # emulation. No-op on native amd64 hosts.
  PLATFORM_FLAG="--platform linux/amd64"
fi

"${CONTAINER_ENGINE}" run --rm ${PLATFORM_FLAG} \
  --env-file "${ENV_FILE}" \
  -e OUT_DIR=/out \
  -v "${PY_FILE}:/reflect.py:ro" \
  -v "${DBSCHEMA_DIR}:/out" \
  "${PYTHON_IMAGE}" \
  bash -c "set -e
${PRE_INSTALL}
pip install --quiet --no-cache-dir --root-user-action=ignore 'SQLAlchemy>=2.0,<3' ${PIP_PKGS}
python /reflect.py"

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
# Use find (exits 0 with no matches, unlike a failing *.sql glob under pipefail).
TABLE_COUNT=$(find "${TABLES_DIR}" -maxdepth 1 -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')
VIEW_COUNT=$(find "${VIEWS_DIR}"  -maxdepth 1 -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')
DATA_COUNT=0
[[ -d "${DATA_DIR}" ]] && DATA_COUNT=$(find "${DATA_DIR}" -maxdepth 1 -name '*.csv' 2>/dev/null | wc -l | tr -d ' ')

echo ""
echo "Done. ${TABLE_COUNT} tables and ${VIEW_COUNT} views written to MANAGE/DBSCHEMA/"
if [[ -n "${DATA_TABLES}" ]]; then
  echo "Data: ${DATA_COUNT} table(s) exported to MANAGE/DBSCHEMA/data/"
fi
echo ""
echo "| Metric               | Value |"
echo "|----------------------|-------|"
echo "| Engine               | ${ENGINE_LABEL} (${DB_TYPE}) |"
echo "| Database             | ${DB_HOST}:${DB_PORT}/${DB_NAME} |"
echo "| Schema               | ${DB_SCHEMA} |"
echo "| Tables exported      | ${TABLE_COUNT} |"
echo "| Views exported       | ${VIEW_COUNT} |"
echo "| Data tables exported | ${DATA_COUNT} |"
echo "| Output directory     | MANAGE/DBSCHEMA/ |"
