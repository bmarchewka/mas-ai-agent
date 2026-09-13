---
name: dbc-scripts
description: Author IBM Maximo (MAS) Manage Database Configuration (.dbc) scripts — the supported, versioned, deployable way to change the Maximo data dictionary (objects, attributes, indexes, relationships), applications and UI (apps, modules, menus, signature options), domains, system properties, maxvars, and seed data. Use when the user wants to create, edit, or review a .dbc script, add a table/attribute/index/relationship, register an application or sigoption, define a domain, add a property/maxvar, or seed configuration data in Maximo/MAS Manage.
user-invocable: true
---

# Authoring Maximo DBC (Database Configuration) Scripts

A **DBC script** (`*.dbc`) is IBM Maximo / MAS Manage's supported, version-controlled,
repeatable way to change the application's *configuration* — its data dictionary (objects,
attributes, indexes, relationships), its UI (applications, modules, menus, signature options),
domains, system properties, maxvars, and seed/config data. Instead of hand-running SQL, you
describe the change declaratively in XML; Maximo's `updatedb`/`configdb` tooling applies it,
records it, keeps the Maximo metadata (MAXOBJECT/MAXATTRIBUTE/MAXTABLE…) in sync with the physical
schema, and can replay the same change across every environment (dev → test → prod).

This skill teaches how to **write a correct DBC script from scratch**. It is grounded in the
official grammar (`script.dtd`) and the ~4,000 scripts IBM ships. Deep-dive material lives in
`reference/`; ready-to-edit skeletons live in `templates/`.

## When to use a DBC script (and when not to)

Use a DBC script for any **persistent configuration change** that must be reproducible and shipped:
- Add/modify/drop a Maximo business object (table), attribute, index, or relationship.
- Register a new application, module, menu, or signature option (security).
- Create/extend a domain (ALN, synonym, numeric, crossover, table).
- Add or set a system property (`maxprop`) or a maxvar.
- Seed configuration/lookup data (`insert`/`update`/`delete`).

Do **not** use a DBC script for: transactional business data (use the app/APIs), one-off ad-hoc
queries, or anything you would not want replayed on every environment. Prefer the typed statements
over `freeform` SQL — reach for `freeform` only when no typed statement covers the change (see
Conventions).

## The authoring workflow

Follow these steps every time you create a `.dbc` script:

1. **State the change precisely** — which object(s)/attribute(s)/app(s), the exact names, types, and
   lengths. Object and attribute names are **UPPERCASE** in Maximo.
2. **Pick the right statement(s)** — see `reference/statements.md` for the full catalog grouped by
   purpose. Prefer a typed statement over `freeform`.
3. **Start from a template** — copy the closest file in `templates/` and adapt it. Look at a shipped
   example of the same statement for conventions (find one with, e.g.
   `grep -rl "<add_attributes" MANAGE/SMP/maximo/tools/maximo/en`).
4. **Make it idempotent** — add a `<check>` block so re-running the script (or running it on an
   environment where the change already exists) safely skips it. See "Idempotency" below.
5. **Get the metadata right** — for attributes, set `maxtype`, `length`/`scale`, `title`, `remarks`,
   and flags correctly (see `reference/attribute-types.md`). Use `sameasobject`/`sameasattribute`
   to inherit a definition from an existing column.
6. **Handle required columns on populated tables** — a new `required="true"` attribute on a table
   that already has rows needs a default, or the change fails; supply `defaultvalue` (and/or add a
   `RequiredColumnDefaults.txt` entry). See `reference/attribute-types.md`.
7. **Validate against the DTD** — `xmllint --noout --dtdvalid script.dtd yourscript.dbc`
   (the DTD is at `MANAGE/SMP/maximo/tools/maximo/script.dtd`).
8. **Name and place the file** — see "File naming & placement" below.
9. **Apply and verify** — see "Applying a script".

## Anatomy of a script

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE script SYSTEM "script.dtd">
<script author="YOURID" scriptname="MYFEATURE">
    <description>Short human-readable summary of the change</description>

    <!-- Optional: skip the script if the change is already present -->
    <check skip_script="true">
        <check_query query="select 1 from maxattribute where objectname='ASSET' and attributename='XYZ'"/>
    </check>

    <statements>
        <!-- one or more typed statements, applied in order -->
    </statements>
</script>
```

- **`<?xml?>` + `<!DOCTYPE script SYSTEM "script.dtd">`** — always present, exactly as shown.
- **`<script>` attributes** — `author` and `scriptname` are **required**. Others: `target`
  (`oracle|sqlserver|db2|all|not_oracle|not_sqlserver|not_db2`, default `all`), `for_demo_only`,
  `for_install_only`, `for_system_down_only`, `context`, `tenantcode`. See `reference/statements.md`.
- **`<description>`** — one line describing the change.
- **`<check>`** (optional, 0+) — idempotency guard; see below.
- **`<statements>`** — the ordered list of changes.

## Idempotency (the `<check>` block)

DBC runs must be safe to re-apply. A `<check>` contains one or more `<check_query>` elements; **if any
query returns at least one row, the script is skipped** (when `skip_script="true"`, the default).
Write the query to detect that the change is *already applied*:

```xml
<check skip_script="true">
    <check_query query="select 1 from maxobject where objectname='MYTABLE'"/>
</check>
```

Rules: no trailing `;` or `go`; keep it a plain `SELECT`; the first check whose query returns a row
wins. Typical probes: `maxobject`/`maxattribute` (schema), `maxapps`/`sigoption` (UI/security),
`maxdomain` (domains), `maxprop` (properties), or the target table itself (seed data — though
`insert ignore_duplicates="true"` is usually simpler for data).

## File naming & placement

Shipped scripts live under `maximo/tools/maximo/en/<product>/` and are named
**`V<version>_<nn>.dbc`** (e.g. `V7503_08.dbc`), applied **in ascending order** within a product.
`.msg` files carry messages, `.mxs` are related resources.

For a **customization**, follow your project's/add-on's convention. The essentials:
- Put the script in the folder your add-on's `updatedb` scans (its product script directory).
- Use a version/sequence **higher than any already applied** for that product so it runs as pending.
- One logical change per script; keep scripts small and focused.

If you are not deploying through a formal add-on, ask the user where their product's script folder is
and what the current version is — do not guess the version prefix.

## Applying a script

Maximo tracks each product's applied version and runs pending `V*` scripts in order via the
**`updatedb`** tool (`maximo/tools/maximo/updatedb.{sh,bat}`; variants: `updatedblite`,
`updatedbsystemup`, `updatedbsystemdown` for `for_system_down_only` scripts; `needtorunupdatedb`
reports whether a run is pending). Older/standalone flows use `configdb`. In **MAS**, `updatedb`
runs as part of the Manage deployment/admin flow rather than by hand.

After applying: confirm the metadata (`MAXOBJECT`/`MAXATTRIBUTE`/`MAXAPPS`/`SIGOPTION`/`MAXDOMAIN`/
`MAXPROP`), that DB config left no object "To Be…" pending, and check the updatedb log for errors.
Applying config changes to existing objects generally requires **admin mode** (config DB).

## Conventions & best practices (distilled from shipped scripts)

- **UPPERCASE** for object, attribute, index, domain, app, and option names.
- **Prefer typed statements** over `<freeform>`. Use `freeform` only for changes with no typed
  equivalent (e.g. updating `maxlogger`, granting existing sigoptions to groups, bulk metadata
  toggles). Freeform SQL bypasses Maximo's metadata sync — you own the consequences.
- **`sameasobject`/`sameasattribute`** — inherit an attribute's type/length from an existing column
  (e.g. a foreign key `same as` its parent's PK) instead of hardcoding.
- **Localization** — for a localizable text column set `localizable="true"`; user-defined text
  objects usually need a matching language table `L_<OBJECT>` (classname `psdi.mbo.LanguageMboSet`)
  with `LANGCODE`/`OWNERID`. See the `define_view`/L_ table example in the shipped MFMAIL scripts.
- **Bind variables** in relationship/where clauses use `:attrname` (lowercase attr), e.g.
  `whereclause="objectname = :mboname"`.
- **XML-escape** inside attribute values and SQL: `&lt;` `&gt;` `&amp;` (e.g. `&lt;&gt;` for `<>`).
- **XML comments must not contain `--`** (a double hyphen) — it makes the file invalid XML. Avoid
  things like `--noout` inside a `<!-- ... -->` comment.
- **Indexes** via `specify_index` (+ `indexkey` per column); set `unique`/`primary` appropriately.
- **Seed data** via `insert` with `ignore_duplicates="true"`; grant new sigoptions to groups with the
  standard `applicationauth` freeform pattern (see `templates/new-application.dbc`).
- **Domains**: `overwrite="false"` unless you intend to replace existing values; mark internal
  domains with a follow-up `update maxdomain set internal=1 …` where appropriate.
- **Required columns on populated tables**: supply `defaultvalue` and/or a `RequiredColumnDefaults.txt`
  entry (`reference/attribute-types.md`) so the `ALTER` can back-fill existing rows.
- **Don't drop lightly** — `drop_attributes`/`drop_table` are destructive and can strand data or
  break references; prefer deprecating.
- **Always** add a `<check>` for anything that isn't naturally idempotent.
- **Validate against the DTD** before shipping, and test on a non-production database first.

## Reference material (load as needed)

- `reference/statements.md` — every statement element, its attributes, purpose, and a real example.
  Read this to choose and fill in a statement.
- `reference/attribute-types.md` — `maxtype` catalog, the full `attrdef`/`modify_attribute` attribute
  set, `columnvalue` value-type attributes, and the required-column-defaults mechanism.
- `templates/` — copy-paste skeletons:
  - `new-table.dbc` — new persistent object + index + relationship
  - `add-attributes.dbc` — add attribute(s) to an existing object (with default for required)
  - `new-application.dbc` — app + sigoptions + menus + grant to groups
  - `add-domain.dbc` — ALN & synonym domains + attach to an attribute
  - `add-property-maxvar.dbc` — system property and maxvar
  - `seed-data.dbc` — idempotent `insert`/`update`
- Ground truth on this machine (from the extracted SMP baseline):
  - DTD: `MANAGE/SMP/maximo/tools/maximo/script.dtd`
  - Examples: `MANAGE/SMP/maximo/tools/maximo/en/<product>/*.dbc` (~4,000 scripts)
  - Required column defaults: `MANAGE/SMP/maximo/tools/maximo/en/script/RequiredColumnDefaults.txt`
  - Apply tooling: `MANAGE/SMP/maximo/tools/maximo/updatedb.*`, `configdb.*`
