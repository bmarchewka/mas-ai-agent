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

## Quick Start

> **What you need first:** a running **Docker** or **Podman**, an **IBM entitlement key** (for the
> `cp.icr.io` images), and **network access** to your Maximo database. Full details in
> [Prerequisites](#prerequisites).

Run **`/mas-workflow`** in your AI agent (IBM Bob, Claude Code, …) and it drives the whole pipeline
for you. The vendor baseline lands in **`MANAGE/<operatorTag>/`** — one folder per configured catalog
release, holding the SMP tree and Graphite app definitions — plus the DB schema in `MANAGE/DBSCHEMA/`
(when `masManage.export: true`), ready to diff against your customizations or against each other.

---

## Prerequisites

| Requirement | Why | Check |
|-------------|-----|-------|
| **A container engine** (running) — Docker **or** Podman | Every step runs inside containers | `docker --version` / `podman --version` |
| **`cp.icr.io` login** | The `manageadmin` and `graphite` images are IBM-entitled | `docker login cp.icr.io` (or `podman login cp.icr.io`) — username `cp`, password = your IBM entitlement key |
| **`yq` (mikefarah) or `python3`** | Reading/writing `config.yaml` (operator tag lists, nested `status.operators`) — either one is enough | `yq --version` / `python3 --version` |
| **Network access to the Maximo DB** | Only when `masManage.export: true` — step 5 connects directly to your database (often needs VPN) | `nc -z -w 5 <db-host> <db-port>` |

Pick the engine with `container.engine` in `config.yaml` (`docker` or `podman`; defaults to `docker`).

`prerequisites.sh` checks the configured container engine and the `config.yaml` parser (`yq` or
`python3`); the registry login and DB reachability are validated when the relevant step actually
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

## Configure `config.yaml`

`config.yaml` has a small `container` toggle plus three sections: you edit `catalog` and
`masManage`; the `status` section is written for you.

### 1. `container` — which container engine to use (input)

```yaml
container:
  engine: docker     # docker | podman
```

Every step runs through this engine. Docker and Podman share the same CLI for everything the
scripts do, so switching is just this one value. **Defaults to `docker`** if the section is
omitted. Whichever you choose must be installed and on your `PATH` (and, for the IBM-entitled
images, logged in — see [Prerequisites](#prerequisites)).

### 2. `catalog` — which operator catalog release(s) to read (input)

```yaml
catalog:
  operatorImage: icr.io/cpopen/ibm-maximo-operator-catalog
  operatorTag: [v9-260827-amd64, v9-261105-amd64]   # or a single tag: v9-260827-amd64
```

| Field | Meaning |
|-------|---------|
| `operatorImage` | The IBM Maximo Operator Catalog image (public registry). Rarely changes. |
| `operatorTag` | One catalog release tag, or a **list** of them (inline `[A, B]` or a block list). Each tag pins which MAS versions get resolved in step 2, and is extracted by steps 3–4 into its own `MANAGE/<tag>/` folder — so you can keep several releases side by side and diff them. |

Steps 2–4 loop over every tag. To process just one, pass `--tag <tag>` (repeatable), e.g.
`bash scripts/mas-manage-SMP-extract.sh --tag v9-261105-amd64`. A tag that fails is reported and the
remaining tags still run; the script exits non-zero at the end if any tag failed.

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

#### Where to put the password (keep the secret out of `config.yaml`)

`config.yaml` is tracked in git, so the DB password should **not** be stored there in plain text.
Step 5 resolves the password in this order:

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

### 4. `status` — resolved images (output, auto-generated)

```yaml
# !! AUTO-GENERATED — do not edit manually !!
status:
  operators:
    v9-260827-amd64:
      catalogImage: icr.io/cpopen/ibm-maximo-operator-catalog:v9-260827-amd64
      manageadmin:  cp.icr.io/cp/manage/manageadmin:<ver>@sha256:...
      graphite:     cp.icr.io/cp/mas/graphite-configuration:<ver>@sha256:...
    v9-261105-amd64:
      ...
```

Written by **step 2** from the catalog — one entry per `catalog.operatorTag`. Each reference is pinned
to an immutable `sha256` digest. The block is rebuilt on every run: tags you removed from
`operatorTag` are dropped, and a tag that fails to resolve keeps its previous entry. Re-run step 2
after changing `catalog.operatorTag`.

---

## Run the workflow

Run the five steps **in order** from the repo root — each depends on the previous one's output.

```bash
bash scripts/prerequisites.sh                 # 1. Check the container engine + yq/python3
bash scripts/mas-manage-resolve-image.sh      # 2. Resolve images per tag -> status.operators.<tag>
bash scripts/mas-manage-SMP-extract.sh        # 3. Copy /opt/IBM/SMP  -> MANAGE/<tag>/SMP/
bash scripts/mas-manage-graphite-extract.sh   # 4. Copy @maximo + unzip apps -> MANAGE/<tag>/GRAPHITE/
bash scripts/mas-manage-db-schema-export.sh   # 5. Export DB schema -> MANAGE/DBSCHEMA/ (only if masManage.export: true)
```

With an AI agent, invoke the skill instead: **`/mas-workflow`**. IBM Bob discovers it
automatically; other agents can read `.bob/skills/mas-workflow/SKILL.md` directly.

Each script prints a small markdown summary table when it finishes — steps 2–4 print one column per
operator tag. **Re-running is safe** — steps 3 and 4 clear and re-mirror `MANAGE/<tag>/SMP` and
`MANAGE/<tag>/GRAPHITE`, and step 5 clears and rewrites the `.sql` (and, when `dataTables` is set, the
`.csv` data) files each run.

### What each step does

| # | Script | Action |
|---|--------|--------|
| 1 | `prerequisites.sh` | Verifies the configured container engine (`docker` or `podman`) is on `PATH`, and that `yq` or `python3` is available. |
| 2 | `mas-manage-resolve-image.sh` | For each operator tag: pulls the operator catalog, finds the `manageadmin` and `graphite-configuration` related images, and writes them to `status.operators.<tag>`. |
| 3 | `mas-manage-SMP-extract.sh` | For each tag: creates a container from the `manageadmin` image and copies `/opt/IBM/SMP/` verbatim (compiled `.class` files kept as-is) to `MANAGE/<tag>/SMP/`. If another tag already extracted the identical image (same digest), it copies locally instead. |
| 4 | `mas-manage-graphite-extract.sh` | For each tag: copies `/graphite/node_modules/@maximo` from the graphite image, then unzips the Graphite app ZIPs found in that tag's SMP tree. |
| 5 | `mas-manage-db-schema-export.sh` | **Only when `masManage.export: true`** (otherwise skipped). Reflects the database schema with SQLAlchemy inside a throwaway `python:3.12-slim-bookworm` container and writes one `.sql` file per table and view (limited to `masManage.schemaTables`). Also exports full row data (CSV) for any tables listed in `masManage.dataTables`. |

---

## Outputs — `MANAGE/`

| Path | Produced by | Contents |
|------|-------------|----------|
| `MANAGE/<tag>/SMP/` | Step 3 | Full SMP tree from that tag's image, including `.class` files. |
| `MANAGE/<tag>/images.yaml` | Step 3 | Manifest of the catalog / `manageadmin` / `graphite` images the folder was built from. |
| `MANAGE/<tag>/GRAPHITE/node_modules/@maximo/` | Step 4 | Graphite `@maximo` packages. |
| `MANAGE/<tag>/GRAPHITE/apps/<app>/` | Step 4 | One folder per unzipped Graphite app definition. |
| `MANAGE/DBSCHEMA/tables/<TABLE>.sql` | Step 5 | `CREATE TABLE` + `CREATE INDEX` per table selected by `masManage.schemaTables`. |
| `MANAGE/DBSCHEMA/views/<VIEW>.sql` | Step 5 | `CREATE VIEW` per view (all views when `schemaTables` is `*`). |
| `MANAGE/DBSCHEMA/data/<TABLE>.csv` | Step 5 | Full row data (CSV) for each table listed in `masManage.dataTables`. |

`MANAGE/DBSCHEMA/` is shared across tags because it comes from your database, not from the vendor
images. `MANAGE/` is generated output — it's meant to be produced by a run, not hand-edited. Comparing
two releases is a plain `diff -r MANAGE/<tagA>/SMP MANAGE/<tagB>/SMP`.
