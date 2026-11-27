<img width="100%" alt="bot2_MAS_AI_Agent" src="https://github.com/user-attachments/assets/8f3664d9-e96c-47d2-a52c-a396e9b1039e" />


Extracts the **IBM Maximo (MAS) Manage vendor baseline** — the SMP folder contents, the
Graphite application definitions, and the database schema — straight from IBM's published
container images and your Maximo database. The point is to have a clean, unmodified copy of what
IBM ships so it can be diffed against your local customizations.

Everything runs through a **container engine** — **Docker** or **Podman**, your choice (set
`container.engine` in your `config.local.yaml`) — so you don't need a local Java, Node, or
database client. The whole pipeline is driven by two config files —
[`config.defaults.yaml`](config.defaults.yaml) (defaults, tracked) and your own `config.local.yaml`
(gitignored) — and the scripts in [`scripts/`](scripts/).

> **Agent-agnostic:** any agentic AI (IBM Bob, Claude Code, Codex, …) can run this by following
> the workflow skill in [`.bob/skills/mas-workflow/SKILL.md`](.bob/skills/mas-workflow/SKILL.md).
> You can also run the scripts by hand as described below — no AI required.

---

## Quick Start

> **What you need first:** a running **Docker** or **Podman**, an **IBM entitlement key** (for the
> `cp.icr.io` images), and **network access** to your Maximo database. Full details in
> [Prerequisites](#prerequisites).

1. Create your local settings file and set your operator catalog tags / versions (and, for step 5,
   your database) in it — see [Configuration](#configuration):

   ```bash
   cp config.local.example.yaml config.local.yaml      # then edit config.local.yaml
   ```

2. Run **`/mas-workflow`** in your AI agent (IBM Bob, Claude Code, …) and it drives the whole pipeline
   for you.

The vendor baseline lands in **`MANAGE/<operatorTag>/`** — one `manage-<version>/` folder per
selected Manage version (SMP tree + Graphite apps) and one `core-<version>/` folder per selected MAS core
version (Graphite framework) — plus the DB schema in `MANAGE/DBSCHEMA/` (when `masManage.export: true`),
ready to diff against your customizations or against each other.

---

## Prerequisites

| Requirement | Why | Check |
|-------------|-----|-------|
| **A container engine** (running) — Docker **or** Podman | Every step runs inside containers | `docker --version` / `podman --version` |
| **`cp.icr.io` login** | The `manageadmin` and `graphite` images are IBM-entitled | `docker login cp.icr.io` (or `podman login cp.icr.io`) — username `cp`, password = your IBM entitlement key |
| **`yq` (mikefarah) or `python3`** | Reading and merging the config files, writing `MANAGE/status.yaml` — either one is enough | `yq --version` / `python3 --version` |
| `python3` *(optional)* | Resolving versions in the operator catalog (step 2). Without it, step 2 runs the resolver in a throwaway `python:3.12-slim-bookworm` container | `python3 --version` |
| **Network access to the Maximo DB** | Only when `masManage.export: true` — step 5 connects directly to your database (often needs VPN) | `nc -z -w 5 <db-host> <db-port>` |

Pick the engine with `container.engine` in `config.local.yaml` (`docker` or `podman`; defaults to `docker`).

`prerequisites.sh` checks the configured container engine, the config parser (`yq` or `python3`) and
the config files (it prints a hint when `config.local.yaml` does not exist yet); the registry login and DB reachability are validated when the relevant step actually
pulls or connects.

### Why an IBM entitlement key is required

The `manageadmin` and `graphite-configuration` images (used by steps 3 and 4) live in
**`cp.icr.io`**, IBM's *entitled* container registry. They are **licensed IBM software** — part of
Maximo Application Suite / the Cloud Pak — so IBM gates them behind an **entitlement key**: a token
tied to your IBM software entitlement that proves you're licensed to run Manage. There is no
anonymous access; the registry refuses an unauthenticated pull outright:

> `unauthorized: Authorization required` — IBM Container Registry

So before steps 3–4 you authenticate once (the login is cached until the key expires or you log out):

```bash
docker login cp.icr.io      # or: podman login cp.icr.io
#   Username: cp
#   Password: <your IBM entitlement key>
```

Get the key from **[myibm.ibm.com → Container software library](https://myibm.ibm.com/products-services/containerlibrary)** ("Get entitlement key" / copy key). The username is always the literal `cp`.

---

## Configuration

The settings are split over two files so that your own values never conflict with updates of the
repository:

| File | In git? | What it holds | Who edits it |
|------|---------|---------------|--------------|
| [`config.defaults.yaml`](config.defaults.yaml) | tracked | **Every** setting with its default value and documentation | the project — don't change it for your installation |
| `config.local.yaml` | **gitignored** | Only the settings **you** change (operator tags, database, …) | you |
| [`config.local.example.yaml`](config.local.example.yaml) | tracked | A starting point for `config.local.yaml` | — |
| `MANAGE/status.yaml` | gitignored | The images resolved by step 2 ([details](#managestatusyaml--resolved-images-output-auto-generated)) | the scripts — don't edit it |

Create your local file once:

```bash
cp config.local.example.yaml config.local.yaml      # then edit it
```

Every script merges `config.local.yaml` over `config.defaults.yaml`:

- **Maps merge key by key; your value wins.** Set only what differs — e.g. just `masManage.export: true`
  — and every other key keeps its default.
- **Lists and single values are replaced as a whole** (`manage: [9.2.x]` replaces the default list,
  it is not appended to it).
- **`catalog.operators` (and the legacy `catalog.operatorTag`) is replaced as a whole** when your file
  sets either, so `config.local.yaml` decides exactly which operator tags run — the default tag does not
  sneak in.
- Without a `config.local.yaml` the defaults run as they are (newest Manage / core of the default
  catalog tag, no DB export).

A minimal `config.local.yaml`:

```yaml
catalog:
  operators:
    v9-261105-amd64:
      manage: [9.2.x, 9.1.x]
      core:   [9.2.x, 9.1.x]
masManage:
  database:
    host: db.example.com
    port: 50000
    type: db2
    name: maxdb
```

**Several setups** (e.g. one per customer): point `MAS_CONFIG` at another local file —
`MAS_CONFIG=config.local.customer-a.yaml bash scripts/mas-manage-resolve-image.sh`. Any
`config.local*.yaml` name is gitignored. The merged result the scripts actually read is written to
`tmp/config.effective.yaml` (`.json` when python3 is the parser) — handy for checking what applies.

The settings are described below. Each snippet shows the keys as you would put them in
`config.local.yaml`; their defaults and comments are in `config.defaults.yaml`.

### 1. `container` — which container engine to use (input)

```yaml
container:
  engine: docker     # docker | podman
```

Every step runs through this engine. Docker and Podman share the same CLI for everything the
scripts do, so switching is just this one value. **Defaults to `docker`** if the section is
omitted. Whichever you choose must be installed and on your `PATH` (and, for the IBM-entitled
images, logged in — see [Prerequisites](#prerequisites)).

### 2. `catalog` — which operator catalog release(s) and versions to read (input)

```yaml
catalog:
  operatorImage: icr.io/cpopen/ibm-maximo-operator-catalog
  operators:
    v9-260827-amd64:                 # nothing set -> manage: [latest], core: [latest]
    v9-261105-amd64:
      manage: [9.2.x, 9.1.x]         # Manage operator versions -> SMP + Graphite apps
      core:   [9.2.x, 9.1.x]         # MAS core versions        -> Graphite @maximo framework
```

| Field | Meaning |
|-------|---------|
| `operatorImage` | The IBM Maximo Operator Catalog image (public registry). Rarely changes. |
| `operators.<tag>` | One entry per catalog release tag. Each tag is a monthly snapshot of which Manage / MAS versions IBM ships. |
| `operators.<tag>.manage` | Manage operator versions (package `ibm-mas-manage`) to extract. Each gets the SMP tree (step 3) and its Graphite app definitions (step 4). |
| `operators.<tag>.core` | MAS core versions (package `ibm-mas`) to extract. Each gets the Graphite `@maximo` framework (step 4) — Graphite ships with MAS core, not with Manage. |

Each `manage` / `core` item can be:

| Item | Resolves to |
|------|-------------|
| `latest` (also when the list is omitted) | Newest stable version in the catalog's `defaultChannel` — what OLM installs by default. |
| `9.2.x` (or `9.2`) | Newest version in that channel. A channel name such as `9.3.x-feature` selects pre-releases. |
| `9.2.4` | That exact version. |

The two lists are independent — pair them as you like (e.g. `9.1.x` in both for a matching Manage
9.1 / core 9.1 set). Versions use the **operator version** (`9.2.6`), as shown in OpenShift and IBM docs;
the image build number (`manageadmin:9.2.265`) is recorded in `status`.

**Older catalogs work too.** Current catalogs list each version's `manageadmin` /
`graphite-configuration` image directly (`source: catalog` in `status`). Older catalogs such as
`v9-250403-amd64`, and older patch bundles in newer ones, list only the operator images. For those,
step 2 reads the image digest that the operator release itself pins (`source: operator`):

| Kind | Trace (each hop reads one vars file out of the image — nothing is run) |
|------|---------------------------------------------------------------------|
| Manage | `ibm-mas-manage` operator → `ibm-mas-manage-primary-entity` → `ibm-mas-manage-ws` → `manage/manageadmin` |
| core | `ibm-mas` operator → `ibm-mas-suite` → `ibm-mas-entitymgr` → `mas/graphite-configuration` |

This needs the same `cp.icr.io` entitlement login as steps 3–4. The operator images pulled for tracing
are removed again and the result is cached in `tmp/image-trace/`, so re-runs are fast. Traced and
listed digests were checked to be identical for releases where the catalog lists both.

**MAS core 9.0 and older ships no Graphite** (`graphite-configuration` arrived with 9.1), so `core`
items such as `9.0.x` — or `latest` in a catalog whose default channel is 9.0.x — are *skipped* with a
note (recorded as `status.operators.<tag>.skipped.core` in `MANAGE/status.yaml`), not failed. Manage 9.0 still gets its SMP and
its Graphite app definitions; there is just no `core-9.0.*` framework folder. An unknown version fails
and lists the valid versions of its channel. To see what a catalog offers before editing the config:

```bash
bash scripts/mas-manage-resolve-image.sh --list-versions [--tag v9-261105-amd64]
#  ibm-mas-manage  (manage: manageadmin image)  defaultChannel: 9.2.x
#    9.2.x    7/7  selectable   9.2.6 (9.2.265) ← latest, 9.2.5 (9.2.258), 9.2.4 (9.2.237), ...
#    9.0.x   30/30 selectable   9.0.34 (9.0.419), ..., 9.0.17 (via operator), ...
#  ibm-mas  (core: graphite image)  defaultChannel: 9.2.x
#    9.2.x    9/9  selectable   9.2.10 (2.5.55) ← latest, 9.2.9 (2.5.52), ...
#    9.0.x    0/32 selectable   — none (MAS core <= 9.0 ships no Graphite ...)
# (via operator) = not listed in this catalog; traced from the operator images when selected
```

Example — Manage 9.0, 9.1 and 9.2 from one current catalog, plus an old catalog's 9.0:

```yaml
  operators:
    v9-261105-amd64:
      manage: [9.0.x, 9.1.x, 9.2.x]
      core:   [9.1.x, 9.2.x]
    v9-250403-amd64:
      manage: [9.0.x]        # -> 9.0.11 (manageadmin 9.0.87, traced)
      core:   [9.0.x]        # -> skipped: no Graphite in core 9.0
```

The older `operatorTag: [v9-260827-amd64, ...]` form still works and means `latest` for both lists.

Steps 2–4 loop over every tag and version. To process a subset, pass `--tag <tag>` and/or (steps 3–4)
`--version <version>` — both repeatable, e.g.
`bash scripts/mas-manage-SMP-extract.sh --tag v9-261105-amd64 --version 9.1.27`. A failing tag or
version is reported and the rest still run; the script exits non-zero at the end if anything failed.

### 3. `masManage` — database export (input)

#### `masManage.export` — run step 5 at all?

```yaml
masManage:
  export: false      # default — step 5 is skipped entirely
  # export: true     # connect to masManage.database and export schemaTables / dataTables
```

Step 5 (DB schema DDL + table data) runs **only when `export: true`**. When it is `false` or omitted,
the step prints a "Skipped" summary and exits successfully without needing DB credentials, network
access to the database, or even the container engine; an existing `MANAGE/DBSCHEMA/` is left untouched.
Accepted values: `true`/`yes`/`on` or `false`/`no`/`off` — anything else is an error.

#### `masManage.database` — your Maximo database connection

```yaml
masManage:
  database:
    host: 63.180.13.40
    port: 1433
    type: mssql        # mssql | db2 | oracle
    name: masdev
    schema: maximo
    username: maximo
    password: env:MAS_DB_PASSWORD    # see "Where to put the password" below
```

| Field | Meaning |
|-------|---------|
| `host` | Database server hostname or IP. |
| `port` | Database port (SQL Server `1433`, DB2 `50000`, Oracle `1521`). |
| `type` | Engine — one of `mssql` (SQL Server), `db2` (IBM DB2), `oracle` (Oracle). Picks the driver automatically. |
| `name` | Database name (SQL Server / DB2) or Oracle **service name**. |
| `schema` | Schema whose tables/views to export (Maximo is usually `maximo` / `MAXIMO`). DB2 and Oracle are folded to upper case automatically. |
| `username` | Read user for reflecting the schema. |
| `password` | The read user's password — **don't put the real secret here**; see below. |

#### Where to put the password (keep the secret out of the config files)

Even though `config.local.yaml` is gitignored, the DB password should **not** be stored there in plain
text. The default `password: env:MAS_DB_PASSWORD` reads it from the environment. Step 5 resolves the
password in this order:

**`MAS_DB_PASSWORD` environment variable** — wins if set. The script also auto-loads a
   **gitignored `secrets.env`** from the repo root, so the easiest setup is:

   ```bash
   cp secrets.env.example secrets.env      # then edit: MAS_DB_PASSWORD=...
   ```

   (Or just `export MAS_DB_PASSWORD=...` in your shell / CI secret store.)

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

### `MANAGE/status.yaml` — resolved images (output, auto-generated)

```yaml
# !! AUTO-GENERATED by scripts/mas-manage-resolve-image.sh (step 2) — do not edit !!
status:
  operators:
    v9-261105-amd64:
      catalogImage: icr.io/cpopen/ibm-maximo-operator-catalog:v9-261105-amd64
      manage:
        9.2.6:
          requested: 9.2.x
          channel: 9.2.x
          bundle: ibm-mas-manage.v9.2.6
          manageadmin: cp.icr.io/cp/manage/manageadmin:9.2.265-amd64@sha256:...
        9.1.27:
          ...
      core:
        9.2.10:
          requested: 9.2.x
          channel: 9.2.x
          bundle: ibm-mas.v9.2.10
          graphite: cp.icr.io/cp/mas/graphite-configuration:2.5.55-amd64@sha256:...
```

Written by **step 2** to `MANAGE/status.yaml` (gitignored, next to the output it describes) and read by
steps 3–4. Per operator tag it holds the resolved versions keyed by operator version, with what you
asked for (`requested`), where the catalog has it (`channel`, `bundle`) and the image pinned to an
immutable `sha256` digest. Items resolving to the same version are merged (`requested: 9.2.x, latest`).
The file is rebuilt on every run: tags you removed are dropped, and a tag whose catalog cannot be read
keeps its previous entry. Re-run step 2 after changing `catalog.operators`.

---

## Run the workflow

Run the five steps **in order** from the repo root — each depends on the previous one's output.

```bash
bash scripts/prerequisites.sh                 # 1. Check the container engine + yq/python3
bash scripts/mas-manage-resolve-image.sh      # 2. Resolve versions per tag -> MANAGE/status.yaml
bash scripts/mas-manage-SMP-extract.sh        # 3. Copy /opt/IBM/SMP  -> MANAGE/<tag>/manage-<ver>/SMP/
bash scripts/mas-manage-graphite-extract.sh   # 4. @maximo -> core-<ver>/GRAPHITE/, apps -> manage-<ver>/GRAPHITE/apps/
bash scripts/mas-manage-db-schema-export.sh   # 5. Export DB schema -> MANAGE/DBSCHEMA/ (only if masManage.export: true)
```

With an AI agent, invoke the skill instead: **`/mas-workflow`**. IBM Bob discovers it
automatically; other agents can read `.bob/skills/mas-workflow/SKILL.md` directly.

Each script prints a small markdown summary table when it finishes — step 2 prints one column per
operator tag, steps 3–4 one column per tag / version. **Re-running is safe** — steps 3 and 4 clear and
re-mirror the `SMP` and `GRAPHITE` folders they write, and step 5 clears and rewrites the `.sql` (and, when `dataTables` is set, the
`.csv` data) files each run.

### What each step does

| # | Script | Action |
|---|--------|--------|
| 1 | `prerequisites.sh` | Verifies the configured container engine (`docker` or `podman`) is on `PATH`, that `yq` or `python3` is available, and that the config files are in place (hints at `cp config.local.example.yaml config.local.yaml` when there is no local file). |
| 2 | `mas-manage-resolve-image.sh` | For each operator tag: pulls the operator catalog and resolves the `manage` / `core` version lists to `manageadmin` / `graphite-configuration` images, written to `status.operators.<tag>` in `MANAGE/status.yaml`. `--list-versions` shows what a catalog offers. |
| 3 | `mas-manage-SMP-extract.sh` | For each tag and Manage version: copies `/opt/IBM/SMP/` from the `manageadmin` image verbatim (compiled `.class` files kept as-is) to `MANAGE/<tag>/manage-<version>/SMP/`. If the identical image (same digest) was already extracted elsewhere, it copies locally instead. |
| 4 | `mas-manage-graphite-extract.sh` | Part A, for each tag and core version: copies `/graphite/node_modules/@maximo` from the graphite image to `MANAGE/<tag>/core-<version>/`. Part B, for each Manage version: unzips the Graphite app ZIPs from its SMP tree. |
| 5 | `mas-manage-db-schema-export.sh` | **Only when `masManage.export: true`** (otherwise skipped). Reflects the database schema with SQLAlchemy inside a throwaway `python:3.12-slim-bookworm` container and writes one `.sql` file per table and view (limited to `masManage.schemaTables`). Also exports full row data (CSV) for any tables listed in `masManage.dataTables`. |

---

## Outputs — `MANAGE/`

| Path | Produced by | Contents |
|------|-------------|----------|
| `MANAGE/status.yaml` | Step 2 | Resolved catalog / bundle / image per tag and version (read by steps 3–4). |
| `MANAGE/<tag>/manage-<version>/SMP/` | Step 3 | Full SMP tree of that Manage version, including `.class` files. |
| `MANAGE/<tag>/manage-<version>/GRAPHITE/apps/<app>/` | Step 4 | One folder per unzipped Graphite app definition of that Manage version. |
| `MANAGE/<tag>/core-<version>/GRAPHITE/node_modules/@maximo/` | Step 4 | Graphite `@maximo` framework of that MAS core version. |
| `MANAGE/<tag>/<kind>-<version>/images.yaml` | Steps 3–4 | Manifest: catalog, package, version, channel, bundle and image the folder was built from. |
| `MANAGE/DBSCHEMA/tables/<TABLE>.sql` | Step 5 | `CREATE TABLE` + `CREATE INDEX` per table selected by `masManage.schemaTables`. |
| `MANAGE/DBSCHEMA/views/<VIEW>.sql` | Step 5 | `CREATE VIEW` per view (all views when `schemaTables` is `*`). |
| `MANAGE/DBSCHEMA/data/<TABLE>.csv` | Step 5 | Full row data (CSV) for each table listed in `masManage.dataTables`. |

`MANAGE/DBSCHEMA/` is shared across tags because it comes from your database, not from the vendor
images. `MANAGE/` is generated output — it's meant to be produced by a run, not hand-edited. Comparing
two versions is a plain `diff -r MANAGE/<tag>/manage-9.1.27/SMP MANAGE/<tag>/manage-9.2.6/SMP`.
