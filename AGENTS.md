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

- `config.yaml` — container engine selector (`container.engine`: `docker` or `podman`, default `docker`), catalog image input (`catalog.operatorImage`, `catalog.operatorTag`), resolved image output (`status.manageadmin`, `status.graphite`), database connection (`masManage.database`), the schema-export selector (`masManage.schemaTables`: `*` for all, or a YAML list such as `[WORKORDER, ASSET, LOCATIONS]`), and the data-export selector (`masManage.dataTables`: same forms — `*` or a YAML list — but empty/absent means none)
- `.bob/skills/mas-workflow/SKILL.md` — the workflow skill: the ordered steps plus how to run them (IBM Bob discovers it automatically; other agents can read it directly)
- `scripts/container-runtime.sh` — shared helper sourced by every script; resolves the container engine (`docker`/`podman`) from `container.engine` and exposes it as `CONTAINER_ENGINE`
- `scripts/prerequisites.sh` — prerequisites check (step 1)
- `scripts/mas-manage-resolve-image.sh` — resolves manageadmin image from operator catalog (step 2)
- `scripts/mas-manage-SMP-extract.sh` — copies the MAS Manage SMP folder from the image (step 3)
- `scripts/mas-manage-graphite-extract.sh` — extracts graphite node_modules/@maximo from container (step 4)
- `scripts/mas-manage-db-schema-export.sh` — exports Maximo DB table/view DDL (for the tables selected by `masManage.schemaTables`), plus full row data (CSV) for the tables listed in `masManage.dataTables`, to MANAGE/DBSCHEMA/ (step 5)
- `MANAGE/SMP/` — extracted SMP contents, including `.class` files kept as-is (populated by step 3)
- `MANAGE/GRAPHITE/node_modules/@maximo` — extracted Graphite @maximo packages (populated by step 4)
- `MANAGE/DBSCHEMA/` — exported schema (one `.sql` per table in `tables/` and per view in `views/`) plus, for tables listed in `masManage.dataTables`, one `.csv` of row data per table in `data/` (populated by step 5)
