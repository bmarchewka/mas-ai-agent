# DBC Statement Catalog

Every element allowed inside `<statements>`, grouped by purpose, with its key attributes and a real
example. Authoritative grammar: `MANAGE/SMP/maximo/tools/maximo/script.dtd`. Required attributes are
marked **(req)**; unmarked ones are optional with the DTD default noted where useful.

## `<script>` and `<check>` (envelope)

**`<script>`** attributes:
| Attribute | Notes |
|-----------|-------|
| `author` **(req)** | Author id (uppercase by convention, e.g. `NISHI2GO`). |
| `scriptname` **(req)** | Logical name of the change/product (e.g. `MFMAIL`). |
| `target` | `oracle\|sqlserver\|db2\|all\|not_oracle\|not_sqlserver\|not_db2` (default `all`). |
| `for_demo_only` / `for_install_only` / `for_system_down_only` | `true\|false` (default `false`). System-down scripts run via `updatedbsystemdown`. |
| `context` | `master\|landlord\|tenants\|all` (multi-tenant). |
| `tenantcode` | Multi-tenant only. |

**`<check>`** / **`<check_query>`** — idempotency. If any `check_query` returns a row, the script is
skipped (`skip_script` default `true`). `<check_query query="…"/>` — plain SELECT, no `;`/`go`.
```xml
<check skip_script="true">
  <check_query query="select 1 from maxattribute where objectname='WORKORDER' and attributename='XYZ'"/>
</check>
```

## Schema: objects / tables

**`<define_table>`** `(attrdef+, longdescription?)` — create a Maximo business object (table).
Key attrs: `object` **(req)**, `description` **(req)**, `service` **(req)**, `type` **(req)**
(`system|site|org|orgsite|companyset|itemset|siteappfilter|orgappfilter|systemappfilter|systemorg|systemorgsite|systemsite|orgwithsite`),
`classname`, `persistent` (default `true`), `primarykey`, `mainobject` (default `false`),
`internal` (default `false`), `unique_column`, `storagetype` (default `tenant`).
```xml
<define_table object="MYTABLE" description="My table" service="CUSTAPP" type="system"
    classname="psdi.mbo.custom.MyTableSet" persistent="true" primarykey="MYTABLEID" mainobject="true">
  <attrdef attribute="MYTABLEID" maxtype="INTEGER" length="12" title="ID" remarks="Primary key"
      persistent="true" required="true" .../>
</define_table>
```

**`<modify_table>`** `(longdescription?)` — change object metadata. `name` **(req)** plus any of
`description`, `service`, `classname`, `type`, `primarykey`, `mainobject`, `internal`, `storagetype`.

**`<drop_table>`** — `object` **(req)**. Destructive.

## Schema: attributes

**`<add_attributes>`** `(attrdef+)` — add columns to an existing object. `object` **(req)**; one
`<attrdef>` per new column.
```xml
<add_attributes object="PERSON">
  <attrdef attribute="DEVICECLASS" maxtype="SMALLINT" length="10" title="Device Class"
      remarks="…" persistent="true" required="false" defaultvalue="2" domain="MFMAILDEVICECLASS"/>
</add_attributes>
```

**`<attrdef>`** — a column definition (used inside `define_table`/`add_attributes`). Full attribute
list and `maxtype` values: see `attribute-types.md`.

**`<modify_attribute>`** — change one column. `object` **(req)**, `attribute` **(req)**, plus any of
the attrdef attributes to change (`maxtype`, `length`, `required`, `title`, `remarks`, `domain`,
`defaultvalue`, `searchtype`, …).

**`<drop_attributes>`** `(attrname+)` — `object` **(req)**; each `<attrname name="COL"/>`. Destructive.

## Schema: indexes

**`<specify_index>`** `(indexkey+)` — create or modify an index. `object` **(req)**, `name`,
`primary` (default `false`), `unique` (default `false`), `clustered` (default `false`),
`required` (default `false`), `addtenantid` (default `true`). Each `<indexkey column="COL"
ascending="true"/>`.
```xml
<specify_index name="MYTABLE_NDX1" object="MYTABLE" unique="true">
  <indexkey column="MYTABLEID" ascending="true"/>
</specify_index>
```
**`<drop_index>`** `(indexkey*)` — `object` **(req)**, by `name` or by matching `indexkey` definition.

## Schema: relationships

**`<create_relationship>`** — a named MBO relationship. `parent` **(req)**, `name` **(req)**,
`child` **(req)**, `whereclause` **(req)**, `remarks` **(req)**, `cardinality`, `isdefault`.
`whereclause` uses `:attr` bind variables (lowercase) referencing the parent's attributes.
```xml
<create_relationship name="MAXOBJECT" parent="MFMAILCFG" child="MAXOBJECT"
    whereclause="objectname = :mboname" remarks="Lookup object description"/>
```
**`<modify_relationship>`** — `parent`+`name` **(req)**, other fields optional.
**`<drop_relationship>`** — `parent`+`name` **(req)**.
**`<logical_relationship>`** — logical FK metadata: `object`, `keys`, `targetobj`, `targetkeys`,
`status` (`unverified|verified|invalidated`) all **(req)**.

## Domains

`overwrite="false"` keeps existing values; set `internal="true"` (or a follow-up
`update maxdomain set internal=1`) for system domains.

**`<specify_aln_domain>`** `(alnvalueinfo+)` — value list. `domainid` **(req)**, `maxtype`
(`ALN|LONGALN|LOWER|UPPER`, default `UPPER`), `length` (default 8). `<alnvalueinfo value="X"
description="…"/>`.

**`<specify_synonym_domain>`** `(synonymvalueinfo+)` — external value ↔ stored maxvalue. `domainid`
**(req)**. `<synonymvalueinfo value="STATUS" maxvalue="STATUS" defaults="true" description="…"/>`.

**`<add_synonyms>`** `(synonymvalueinfo+)` — add values to an existing synonym domain. `domainid` **(req)**.

**`<specify_numeric_domain>`** `(numericvalueinfo+)` — `domainid` **(req)**, `maxtype`
(`AMOUNT|DECIMAL|DURATION|FLOAT|INTEGER|SMALLINT`, default `INTEGER`), `length`, `scale`.

**`<specify_crossover_domain>`** `(crossovervalueinfo+)` / **`<specify_table_domain>`** — table &
crossover domains. `domainid`, `validationwhereclause`, `objectname` **(req)**; crossover value rows
map `sourcefield`→`destfield`.

**`<drop_domain>`** — `domainid` **(req)**.
**`<modify_domain_type>`** — change a domain's `maxtype`/`length`/`scale`.

## Applications, modules, menus, security

**`<create_app>`** `(longdescription?)` — `app` **(req)**, `description` **(req)**, `maintbname`,
`apptype`, `restrictions`, `orderby`, `ismobile`. **`<modify_app>`**, **`<drop_app>`** (also drops
related sigoption/maxmenu rows).

**`<create_module>`** `(module_menu_app|module_menu_header)+` — `module` **(req)**, `description`
**(req)**, `menu_position`, `image`. **`<modify_module>`**, **`<drop_module>`**.
**`<module_app>`** — add an app to a module menu: `module` **(req)**, `app` **(req)**.

**`<add_sigoption>`** `(longdescription?)` — a security/signature option. `app` **(req)**,
`optionname` **(req)**, `description` **(req)**, `esigenabled` (default `false`), `visible`
(default `true`), `alsogrants`, `alsorevokes`, `prerequisite`, `grantapp`, `grantoption`,
`granteveryone`, `grantcondition`.
```xml
<add_sigoption app="MFMAILCFG" optionname="SAVE" description="Save Configuration"
    alsogrants="" alsorevokes="INSERT,DUPLICATE,DELETE" esigenabled="false"/>
```
**`<drop_sigoption>`** — `app`+`optionname` **(req)**.

**`<create_app_menu>`** `(app_menu_option|menu_separator|app_menu_header)+` — build an app's menu.
`app` **(req)**, `type` (`action|tool|search`, default `action`). `<app_menu_option option="…"
tabdisplay="LIST|MAIN|ALL" image="…" accesskey="…"/>`, `<menu_separator/>`, `<app_menu_header
headerdescription="…">…</app_menu_header>`.
**`<additional_app_menu>`** — append to an existing menu (`menu_position`, `pos_param`).
**`<remove_menu_option>`** — `app`+`type`+`option` **(req)**.

## Services

**`<add_service>`** — register an MBO service: `servicename` **(req)**, `description` **(req)**,
`classname` **(req)**, `singleton`, `initorder`, `internal`, `active`.
**`<modify_service>`**, **`<drop_service>`**.

## System properties & maxvars

**`<add_property>`** — a `maxprop` system property. `name` **(req)**, `description` **(req)**,
`maxtype` (`ALN|INTEGER|YORN`) **(req)**, `secure_level` (`private|public|secure|mtsecure`)
**(req)**, `scope` (`global|instance|open`, default `open`), `default_value`, `value`,
`live_refresh`, `online_changes`, `required`, `encrypted`, `masked`, `domainid`.
```xml
<add_property name="mxe.mfmail.AssistMarker" description="…" maxtype="ALN" secure_level="public"
    scope="global" value="#@" default_value="#@" live_refresh="true" online_changes="true"/>
```
**`<set_property>`** — `name`+`value` **(req)**. **`<drop_property>`** — `name` **(req)**.

**`<create_maxvar>`** — `name` **(req)**, `description` **(req)**, `type`
(`system|site|organization|system_tenant`) **(req)**, `default`.
**`<modify_maxvar>`**, **`<drop_maxvar>`** — `name` **(req)**.

## Views

**`<define_view>`** — a database/MBO view. Two forms: autoselect over base `<table>`s + optional
`<view_column>`s, **or** explicit `<view_column>+`, `<view_select>`, `<view_from>`; both need
`<view_where>`. Attrs: `name`, `description`, `service`, `classname`, `type` all **(req)**.
**`<modify_view>`**, **`<drop_view>`**, **`<add_view_attribute>`**, **`<drop_view_attribute>`**,
**`<modify_view_attributes>`** (`modify_view_data+`).

## Data (seed/config)

**`<insert>`** `(insertrow+)` — `table` **(req)**, `ignore_duplicates` (default `false`; set `true`
for idempotent seeds), `selectfrom`/`selectwhere` (insert-from-select). Each `<insertrow>` holds
`<columnvalue>`s. Column value-type attributes (`string`/`number`/`boolean`/`date`/`domainvalue`+
`domainid`/`fromcolumn`/`selectnumber`/`selectstring`/`clob`/`blob`/`offset_days`) — see
`attribute-types.md`.
```xml
<insert table="applicationauth" ignore_duplicates="true">
  <insertrow>
    <columnvalue column="app" string="MXAPIASSET"/>
    <columnvalue column="optionname" string="READ"/>
    <columnvalue column="groupname" string="MAXADMIN"/>
  </insertrow>
</insert>
```

**`<update>`** `(set, where*, whereclause*)` — `table` **(req)**. `<set>` holds `columnvalue`s
(the SET clause); `<where>` holds `columnvalue`s ANDed as equals; `<whereclause value="…"/>` for
free-form conditions.

**`<delete>`** `(where*, whereclause*)` — `table` **(req)**. Same where forms as `update`.

## Escape hatch: freeform SQL

**`<freeform>`** `(sql+)` — `description` **(req)**. Each `<sql target="…">…</sql>` runs verbatim
(`target` narrows to a DB engine). Use only when no typed statement fits — it bypasses metadata sync.
```xml
<freeform description="Grant new options to existing groups">
  <sql target="all">insert into applicationauth (groupname, app, optionname, applicationauthid)
    (select groupname, 'MFMAILCFG', optionname, applicationauthseq.nextval
     from applicationauth where app = 'MFMAILCFG');</sql>
</freeform>
```
