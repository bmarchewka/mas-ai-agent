# mas-agent

Automates extraction of IBM Maximo (MAS) Manage SMP contents, Graphite application definitions,
and database schema from IBM's published container images — so the vendor baseline can be compared
against local customizations. Every step runs through a container engine chosen in `config.yaml`
(`container.engine`: `docker` or `podman`).

This project is **agent-agnostic**: any agentic AI (Claude Code, Codex, IBM Bob, etc.) can run it
by following the instructions in this file. There is no tool-specific configuration required — all
work is driven by `config.yaml` and the shell scripts in `scripts/`.

## Workflow

The end-to-end workflow is defined as a single skill in `.bob/skills/mas-workflow/SKILL.md`. It
lists the ordered steps (each maps to a script in `scripts/` and specifies the exact summary table
to print when it finishes) and explains how to turn them into a task list / checklist.

IBM Bob discovers this skill automatically — invoke it with `/mas-workflow`, or Bob may activate it
on its own when a request matches the skill's description. Other agents can simply read
`.bob/skills/mas-workflow/SKILL.md` directly; the SKILL.md format is a shared convention, so no
per-tool copy is needed.

## Key Files

- `config.yaml` — container engine selector (`container.engine`: `docker` or `podman`, default `docker`), catalog input (`catalog.operatorImage`, and `catalog.operators` — per operator catalog tag, independent `manage` and `core` version lists whose items are `latest`, a channel such as `9.2.x`, or an exact version such as `9.2.4`; the legacy `catalog.operatorTag` list means `latest`), resolved output (`status.operators.<tag>.catalogImage`, `.manage.<version>.{requested,channel,bundle,source,manageadmin}`, `.core.<version>.{requested,channel,bundle,source,graphite}`, `.skipped.core` for core items ≤ 9.0, which ship no Graphite; `source` is `catalog` or `operator`), the DB-export switch (`masManage.export`: `true` runs step 5, `false`/absent — the default — skips it), database connection (`masManage.database`), the schema-export selector (`masManage.schemaTables`: `*` for all, or a YAML list such as `[WORKORDER, ASSET, LOCATIONS]`), and the data-export selector (`masManage.dataTables`: same forms — `*` or a YAML list — but empty/absent means none)
- `.bob/skills/mas-workflow/SKILL.md` — the workflow skill: the ordered steps plus how to run them (IBM Bob discovers it automatically; other agents can read it directly)
- `scripts/config-lib.sh` — shared helper sourced by the workflow scripts: nested `config.yaml` reads/writes (yq, or python3 via `scripts/config_yaml.py`), operator tags and version lists, and the per-tag / per-version runner (`--tag` / `--version` options, combined one-column-per-unit summary table)
- `scripts/config_yaml.py` — dependency-free python3 fallback parser/writer for `config.yaml`, used when the mikefarah `yq` is not installed
- `scripts/catalog_resolve.py` — resolves `manage` / `core` version specs against the operator catalog's OLM channels and bundles (stdlib python; run on the host or in a python container); `list` mode backs `--list-versions`; `lookup` reads image digests out of operator vars files for tracing
- `scripts/container-runtime.sh` — shared helper sourced by every script; resolves the container engine (`docker`/`podman`) from `container.engine` and exposes it as `CONTAINER_ENGINE`
- `scripts/prerequisites.sh` — prerequisites check: container engine + `yq` or `python3` (step 1)
- `scripts/mas-manage-resolve-image.sh` — resolves each tag's `manage` / `core` version lists against the operator catalog into `status.operators.<tag>`; for older catalogs whose bundles do not list the `manageadmin` / `graphite-configuration` image it traces the digest pinned inside the operator images (cached in `tmp/image-trace/`); `--list-versions` shows the selectable versions (step 2)
- `scripts/mas-manage-SMP-extract.sh` — copies the MAS Manage SMP folder of each resolved Manage version to `MANAGE/<tag>/manage-<version>/SMP/` (step 3)
- `scripts/mas-manage-graphite-extract.sh` — extracts the Graphite @maximo framework of each resolved core version to `MANAGE/<tag>/core-<version>/GRAPHITE/`, and unzips each Manage version's Graphite apps to `MANAGE/<tag>/manage-<version>/GRAPHITE/apps/` (step 4)
- `scripts/mas-manage-db-schema-export.sh` — exports Maximo DB table/view DDL (for the tables selected by `masManage.schemaTables`), plus full row data (CSV) for the tables listed in `masManage.dataTables`, to MANAGE/DBSCHEMA/ (step 5) — only when `masManage.export: true`; otherwise the step is skipped. The DB password is resolved from (in order) the `MAS_DB_PASSWORD` env var / gitignored `secrets.env`, then `masManage.database.password` which may be a literal or an `env:VAR` / `file:/path` / `cmd:<command>` reference — keep the real secret out of the tracked `config.yaml`
- `secrets.env.example` — template for local DB credentials; copy to `secrets.env` (gitignored) and set `MAS_DB_PASSWORD` (auto-loaded by step 5)
- `MANAGE/<tag>/manage-<version>/SMP/` — extracted SMP contents of that Manage version, including `.class` files kept as-is (populated by step 3)
- `MANAGE/<tag>/manage-<version>/GRAPHITE/apps/` — unzipped Graphite app definitions of that Manage version (populated by step 4)
- `MANAGE/<tag>/core-<version>/GRAPHITE/node_modules/@maximo` — Graphite @maximo framework of that MAS core version (populated by step 4)
- `MANAGE/<tag>/<manage|core>-<version>/images.yaml` — manifest of what the folder was extracted from (steps 3–4)
- `MANAGE/DBSCHEMA/` — exported schema (one `.sql` per table in `tables/` and per view in `views/`) plus, for tables listed in `masManage.dataTables`, one `.csv` of row data per table in `data/` (populated by step 5 when `masManage.export: true`; shared across operator tags)
