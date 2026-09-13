---
name: mas-workflow
description: Run the mas-agent extraction pipeline for IBM Maximo (MAS) Manage — validate prerequisites, resolve the manageadmin and Graphite images from the operator catalog, extract the SMP folder contents, extract Graphite app definitions, and export the Maximo DB schema. Use when the user wants to scaffold or run the mas-agent workflow, extract MAS Manage source, or refresh the vendor baseline.
user-invocable: true
---

# mas-agent Workflow

This skill defines the end-to-end mas-agent extraction pipeline **and** explains how
to turn it into a task list you can execute step by step. It is agent-agnostic — the SKILL.md format
is shared across IBM Bob, Claude Code, and similar tools, so the same file works everywhere.

All work is driven by `config.yaml` and the shell scripts in `scripts/` (see `AGENTS.md` for the
full file map).

## How to run

1. Present the steps below as a task list / checklist — one item per numbered step, in order — using
   whatever task-tracking mechanism your tool provides (a native task/plan capability or a plain
   markdown checklist).
2. Execute each step in sequence by running its script in `scripts/`. Each step depends on the
   output of the previous ones, so do not skip ahead.
3. After each step completes, print the summary table specified for that step.
4. While scaffolding the task list (before execution), do not modify any project files.
5. Re-running is safe: create a fresh task list rather than trying to de-duplicate against a
   previous run.

## Workflow steps

1. **Validate prerequisites** — Check that the configured container engine (`container.engine` in `config.yaml` — `docker` or `podman`, default `docker`) is available on PATH (every workflow step runs through it), then run `scripts/prerequisites.sh`. After completion, always display results as a markdown table with columns: Tool, Status, Version.
2. **Resolve manageadmin image from operator catalog** — Parse `catalog.operatorImage` and `catalog.operatorTag` from `config.yaml`, pull the IBM Maximo Operator Catalog image, extract `/configs/` (OLM NDJSON bundles), find the `manageadmin` entry in `relatedImages`, and write the resolved image URL to `status.manageadmin` in `config.yaml`. Implemented in `scripts/mas-manage-resolve-image.sh`. After completion, always display results as a markdown table with columns: Metric, Value. Rows: Catalog image, Catalog tag, Resolved image, Written to.
3. **Extract MAS Manage SMP folder** — Parse `manageadmin` image tag from `status.manageadmin` in `config.yaml`, create/reuse a container, and copy `/opt/IBM/SMP/` (via `<engine> cp`) into local `MANAGE/SMP/`. Files are copied verbatim, including compiled `.class` files, which are kept exactly as shipped in the image. Implemented in `scripts/mas-manage-SMP-extract.sh`. After completion, always display results as a markdown table with columns: Metric, Value. Rows: Image, Container, Class files, Total files in MANAGE/SMP/.
4. **Extract Graphite node_modules/@maximo** — Parse `status.graphite` image reference from `config.yaml`, create/reuse a container, copy `/graphite/node_modules/@maximo` into local `MANAGE/GRAPHITE/node_modules/@maximo`. Then unzip all Graphite app ZIP files from `MANAGE/SMP/maximo/tools/maximo/en/graphite/apps/` into `MANAGE/GRAPHITE/apps/`, one subdirectory per app named after the ZIP file (without `.zip` extension). Implemented in `scripts/mas-manage-graphite-extract.sh`. After completion, always display results as a markdown table with columns: Metric, Value. Rows: Image, Container, Files copied, Output directory, Apps unzipped, Apps directory.
5. **Export Maximo DB schema (and selected table data) to MANAGE/DBSCHEMA/** — Parse `masManage.database` fields (type, host, port, name, username, password, schema) from `config.yaml` and connect to the database using the engine named by `masManage.database.type`. Supported engines: `mssql` (SQL Server), `db2` (IBM DB2), and `oracle` (Oracle) — the engines IBM Maximo / MAS Manage runs on. The tables whose DDL is exported are selected by `masManage.schemaTables` in `config.yaml`: `*` (or the key absent) exports every table and view, while a YAML list such as `[WORKORDER, ASSET, LOCATIONS]` (inline or block form) limits the export to those objects (matched case-insensitively). Reflect the schema with SQLAlchemy and write each selected table's `CREATE TABLE` DDL (columns, types, constraints, primary keys, foreign keys) plus its `CREATE INDEX` statements to `MANAGE/DBSCHEMA/tables/<TABLE_NAME>.sql`, and each view definition to `MANAGE/DBSCHEMA/views/<VIEW_NAME>.sql`. In addition, export full row DATA as CSV for the tables selected by `masManage.dataTables` (same forms as `schemaTables`: `*` for all tables, or a YAML list such as `[MAXRELATIONSHIP, WORKORDER]`; but absent or empty means no data export). Each table is streamed (so million-row tables are handled) to `MANAGE/DBSCHEMA/data/<TABLE_NAME>.csv` — one file per table, named after the table, with a header row and SQL `NULL` written as an empty field. Creates the output directories if absent. Runs inside a dedicated `python:3-slim` container that is automatically removed when the export completes — no local database client or SQL tooling required, only the configured container engine (`docker` or `podman`). On ARM hosts (e.g. Apple Silicon) the DB2 engine runs the container under `--platform linux/amd64` automatically because IBM's `ibm_db` driver has no ARM64 build. Implemented in `scripts/mas-manage-db-schema-export.sh`. After completion, always display results as a markdown table with columns: Metric, Value. Rows: Engine, Database, Schema, Tables exported, Views exported, Data tables exported, Output directory.
