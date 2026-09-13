<img width="100%" alt="bot2_MAS_AI_Agent" src="https://github.com/user-attachments/assets/8f3664d9-e96c-47d2-a52c-a396e9b1039e" />


Extracts the **IBM Maximo (MAS) Manage vendor baseline** — the SMP folder contents, the
Graphite application definitions, and the database schema — straight from IBM's published
container images and your Maximo database. The point is to have a clean, unmodified copy of what
IBM ships so it can be diffed against your local customizations.

Everything runs through a **container engine** — **Docker** or **Podman**, your choice (set
`container.engine` in [`config.yaml`](config.yaml)) — so you don't need a local Java, Node, or
database client. The whole pipeline is driven by [`config.yaml`](config.yaml) and the scripts in
[`scripts/`](scripts/).

> **Agent-agnostic:** any agentic AI (IBM Bob, Claude Code, Codex, …) can run this by following
> the workflow skill in [`.bob/skills/mas-workflow/SKILL.md`](.bob/skills/mas-workflow/SKILL.md).
> You can also run the scripts by hand as described below — no AI required.

---

## Prerequisites

| Requirement | Why | Check |
|-------------|-----|-------|
| **A container engine** (running) — Docker **or** Podman | Every step runs inside containers | `docker --version` / `podman --version` |
| **`cp.icr.io` login** | The `manageadmin` and `graphite` images are IBM-entitled | `docker login cp.icr.io` (or `podman login cp.icr.io`) — username `cp`, password = your IBM entitlement key |
| **Network access to the Maximo DB** | Step 5 connects directly to your database (often needs VPN) | `nc -z -w 5 <db-host> <db-port>` |

Pick the engine with `container.engine` in `config.yaml` (`docker` or `podman`; defaults to `docker`).
The operator catalog image (`icr.io/cpopen/...`) is public, so step 2 needs no login.

`prerequisites.sh` only checks the configured container engine; the registry login and DB
reachability are validated when the relevant step actually pulls or connects.

---

## Configure `config.yaml`

`config.yaml` has a small `container` toggle plus three sections: you edit `catalog` and
`masManage`; the `status` section is written for you.

### 0. `container` — which container engine to use (input)

```yaml
container:
  engine: docker     # docker | podman
```

Every step runs through this engine. Docker and Podman share the same CLI for everything the
scripts do, so switching is just this one value. **Defaults to `docker`** if the section is
omitted. Whichever you choose must be installed and on your `PATH` (and, for the IBM-entitled
images, logged in — see [Prerequisites](#prerequisites)).

### 1. `catalog` — which operator catalog release to read (input)

```yaml
catalog:
  operatorImage: icr.io/cpopen/ibm-maximo-operator-catalog
  operatorTag: v9-260827-amd64
```

| Field | Meaning |
|-------|---------|
| `operatorImage` | The IBM Maximo Operator Catalog image (public registry). Rarely changes. |
| `operatorTag` | The catalog release tag. This pins which MAS versions get resolved in step 2. Change this to target a different catalog release. |

### 2. `masManage.database` — your Maximo database connection (input)

```yaml
masManage:
  database:
    host: 63.180.13.40
    port: 1433
    type: mssql        # mssql | db2 | oracle
    name: masdev
    schema: maximo
    username: maximo
    password: ********
```

| Field | Meaning |
|-------|---------|
| `host` | Database server hostname or IP. |
| `port` | Database port (SQL Server `1433`, DB2 `50000`, Oracle `1521`). |
| `type` | Engine — one of `mssql` (SQL Server), `db2` (IBM DB2), `oracle` (Oracle). Picks the driver automatically. |
| `name` | Database name (SQL Server / DB2) or Oracle **service name**. |
| `schema` | Schema whose tables/views to export (Maximo is usually `maximo` / `MAXIMO`). DB2 and Oracle are folded to upper case automatically. |
| `username` / `password` | Read credentials for reflecting the schema. |

> **Credentials:** `config.yaml` holds the DB password in plain text. Treat this file as sensitive —
> avoid committing real production credentials, or keep them in a copy that stays out of version control.

#### `masManage.schemaTables` — which tables' schema to export

Controls which tables (and views) get their **DDL** exported in step 5:

```yaml
masManage:
  database:
    ...
  schemaTables: "*"                             # all tables + views (default)
  # schemaTables: [WORKORDER, ASSET, LOCATIONS] # only these (YAML list)
```

- **`"*"`** (or omitting the key) exports every table and every view — the default.
- A **YAML list** — `[WORKORDER, ASSET, LOCATIONS]` (inline) or a block list (`- WORKORDER` per line) —
  limits the export to just those objects. Names are matched **case-insensitively** (`WORKORDER` ==
  `workorder`), and a name that matches neither a table nor a view is reported as a `WARNING` and skipped.
- When you narrow the list, only the matching tables' `.sql` files (and any matching views') are
  written — this is also much faster, since only the requested tables are reflected instead of all of them.

#### `masManage.dataTables` — export table *data* (optional)

By default step 5 exports only the **schema** (DDL). To also export the full **row data** of specific
tables, set `masManage.dataTables` (a sibling of `database`). It takes the **same forms as
`schemaTables`** — a YAML list or `"*"`:

```yaml
masManage:
  database:
    ...
  dataTables: [MAXRELATIONSHIP, WORKORDER]  # a YAML list (inline or block), OR:
  # dataTables:
  #   - MAXRELATIONSHIP
  #   - MAXATTRIBUTE
  # dataTables: "*"                          # data for ALL tables (can be huge!)
```

- Each selected table is dumped to **`MANAGE/DBSCHEMA/data/<TABLE>.csv`** — one file per table, named
  after the table (matching its `.sql` DDL file). The `data/` folder is created automatically.
- **`"*"`** exports data for **every** table in the schema — regardless of `schemaTables` — so use it
  carefully; it can produce a very large amount of data.
- Table names are matched case-insensitively, so `MAXRELATIONSHIP`, `maxrelationship`, etc. all work.
- **Omit the key (or leave it empty) to export DDL only** — no `data/` folder is produced. (This is the
  key difference from `schemaTables`, where an empty value means *all*; for data, empty means *none*.)
- Re-running rewrites the `data/` folder: files for the currently-selected tables are refreshed, and
  files from tables you removed are deleted.

**Why CSV?** These exports can reach **millions of rows**, and CSV is the most compact and
stream-friendly format for that scale — far smaller than JSON/JSONL (which repeat every column name on
every row) and read natively by `head`/`grep`/`awk`, `duckdb`, `pandas`, and AI agents. Each file has a
header row of column names; values use standard CSV quoting (RFC 4180). **SQL `NULL` is written as an
empty field** (indistinguishable from an empty string — keep that in mind when analysing the data).

### 3. `status` — resolved images (output, auto-generated)

```yaml
# !! AUTO-GENERATED — do not edit manually !!
status:
  manageadmin: cp.icr.io/cp/manage/manageadmin:<tag>@sha256:...
  graphite:    cp.icr.io/cp/mas/graphite-configuration:<tag>@sha256:...
```

Written by **step 2** from the catalog. Each reference is pinned to an immutable `sha256` digest.
Re-run step 2 to refresh these after changing `catalog.operatorTag`.

---

## Run the workflow

Run the five steps **in order** from the repo root — each depends on the previous one's output.

```bash
bash scripts/prerequisites.sh                 # 1. Check the container engine (docker/podman) is available
bash scripts/mas-manage-resolve-image.sh      # 2. Resolve manageadmin + graphite images -> status.*
bash scripts/mas-manage-SMP-extract.sh        # 3. Copy /opt/IBM/SMP  -> MANAGE/SMP/
bash scripts/mas-manage-graphite-extract.sh   # 4. Copy @maximo + unzip apps -> MANAGE/GRAPHITE/
bash scripts/mas-manage-db-schema-export.sh   # 5. Export DB schema -> MANAGE/DBSCHEMA/
```

With an AI agent, invoke the skill instead: **`/mas-workflow`**. IBM Bob discovers it
automatically; other agents can read `.bob/skills/mas-workflow/SKILL.md` directly.

Each script prints a small markdown summary table when it finishes. **Re-running is safe** — step 3
mirrors the SMP tree, step 4 re-copies and re-unzips, and step 5 clears and rewrites the `.sql`
(and, when `dataTables` is set, the `.csv` data) files each run.

### What each step does

| # | Script | Action |
|---|--------|--------|
| 1 | `prerequisites.sh` | Verifies the configured container engine (`docker` or `podman`) is on `PATH`. |
| 2 | `mas-manage-resolve-image.sh` | Pulls the operator catalog, finds the `manageadmin` and `graphite-configuration` related images, and writes them to `status.*`. |
| 3 | `mas-manage-SMP-extract.sh` | Creates a container from the `manageadmin` image and copies `/opt/IBM/SMP/` verbatim (compiled `.class` files kept as-is). |
| 4 | `mas-manage-graphite-extract.sh` | Copies `/graphite/node_modules/@maximo` from the graphite image, then unzips the Graphite app ZIPs found in the extracted SMP tree. |
| 5 | `mas-manage-db-schema-export.sh` | Reflects the database schema with SQLAlchemy inside a throwaway `python:3.12-slim-bookworm` container and writes one `.sql` file per table and view (limited to `masManage.schemaTables`). Also exports full row data (CSV) for any tables listed in `masManage.dataTables`. |

---

## Outputs — `MANAGE/`

| Path | Produced by | Contents |
|------|-------------|----------|
| `MANAGE/SMP/` | Step 3 | Full SMP tree from the image, including `.class` files. |
| `MANAGE/GRAPHITE/node_modules/@maximo/` | Step 4 | Graphite `@maximo` packages. |
| `MANAGE/GRAPHITE/apps/<app>/` | Step 4 | One folder per unzipped Graphite app definition. |
| `MANAGE/DBSCHEMA/tables/<TABLE>.sql` | Step 5 | `CREATE TABLE` + `CREATE INDEX` per table selected by `masManage.schemaTables`. |
| `MANAGE/DBSCHEMA/views/<VIEW>.sql` | Step 5 | `CREATE VIEW` per view (all views when `schemaTables` is `*`). |
| `MANAGE/DBSCHEMA/data/<TABLE>.csv` | Step 5 | Full row data (CSV) for each table listed in `masManage.dataTables`. |

`MANAGE/` is generated output — it's meant to be produced by a run, not hand-edited.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `... pull access denied` on `cp.icr.io` | Not logged in / expired entitlement key. Run `docker login cp.icr.io` (or `podman login cp.icr.io`) — user `cp`, password = IBM entitlement key. Log in to the same engine you set in `container.engine`. |
| Step 5: `Unable to connect ... Connection timed out`, or DB2 `SQL30081N ... Communication error ... "connect" ... error code(s): "111"` (connection refused) | The DB host isn't reachable from your machine. Connect to the required VPN / open the firewall, verify `masManage.database` host & port, then test with `nc -z -w 5 <host> <port>` and re-run step 5 only. The container inherits the host's network, so if the host can't reach the DB, neither can the export — fix reachability on the host first. |
| `WARNING: ... platform (linux/amd64) does not match ... arm64` | Harmless on Apple Silicon — files are only read/copied out of the image, never executed. |
| Step 5: `WARNING: schema '<x>' had no tables; using default schema` | The configured `schema` was empty; the exporter fell back to the driver's default (e.g. SQL Server `dbo`). Set `masManage.database.schema` correctly if that's not what you want. |
| Step 5 (DB2) on Apple Silicon: `ibm_db` fails to install (`NameError: name 'arch_' is not defined`) | IBM's DB2 driver has no ARM64 build. The script handles this automatically by running the DB2 container as `--platform linux/amd64` (needs amd64 emulation — Docker Desktop has it on by default; for Podman ensure `qemu-user-static` is available in the machine, which the default `podman machine` image ships). Nothing to do — just expect it to run slower under emulation. |
| Podman: `Error: ... no such file or directory` mounting a temp file in step 5 | Podman on macOS only bind-mounts paths inside the machine's shared mounts (your home dir). The script already writes its temp files under the repo's `tmp/`; make sure the repo lives under your home directory (the default shared path), or add its parent to `podman machine` shared mounts. |
| Step 5: `WARNING: data table '<name>' not found ... skipped` | A name in `masManage.dataTables` doesn't match a real table in the resolved schema. Check the spelling; matching is case-insensitive but the table must exist. |

---

## Repository layout

```
config.yaml                        # inputs (container engine, catalog, database) + generated status
scripts/                           # one script per workflow step
scripts/container-runtime.sh       # shared helper: resolves the docker|podman engine from config
.bob/skills/mas-workflow/SKILL.md  # the workflow definition (agent-discoverable)
MANAGE/                            # generated output (SMP / GRAPHITE / DBSCHEMA)
AGENTS.md, CLAUDE.md               # agent-facing project instructions
README.md                          # this file
```
