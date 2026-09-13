# Attribute types, `attrdef`, `columnvalue`, and required-column defaults

Companion to `statements.md`. Grounded in `script.dtd` and `RequiredColumnDefaults.txt`.

## `maxtype` — Maximo attribute data types

Used on `<attrdef>`, `<modify_attribute>`, `<attrmod>` (and, restricted subsets, on domains).

| maxtype | Meaning / physical | Notes |
|---------|--------------------|-------|
| `ALN` | Alphanumeric (mixed case) | General text; set `length`. |
| `UPPER` | Text stored UPPERCASE | Codes, keys, names, foreign keys. |
| `LOWER` | Text stored lowercase | Rare. |
| `LONGALN` | Long text | Long descriptions / large text; used with `haslongdesc`. |
| `INTEGER` | 4-byte integer | `length` ~12 by convention. |
| `SMALLINT` | Small integer | |
| `BIGINT` | 8-byte integer | Large ids. |
| `DECIMAL` | Fixed decimal | Set `length` + `scale`. |
| `FLOAT` | Floating point | |
| `AMOUNT` | Currency amount | Money fields. |
| `DURATION` | Duration | Hours (decimal). |
| `YORN` | Yes/No | Stored 1/0; `length="1"`, usually `defaultvalue="0"`. |
| `DATE` / `DATETIME` / `TIME` | Temporal | |
| `CLOB` / `BLOB` | Large object | Character / binary LOB. |
| `GL` | GL account | General ledger account field. |
| `CRYPTO` / `CRYPTOX` | Encrypted text | Passwords/secrets (CRYPTOX = one-way). |

Domain-only subsets: ALN domains → `ALN|LONGALN|LOWER|UPPER`; numeric domains →
`AMOUNT|DECIMAL|DURATION|FLOAT|INTEGER|SMALLINT`.

## `<attrdef>` attributes (defining a column)

Required: `attribute`, `title`, `remarks`. Everything else is optional (DTD defaults shown).

| Attribute | Default | Purpose |
|-----------|---------|---------|
| `attribute` **(req)** | — | Column name (UPPERCASE). |
| `maxtype` | — | Data type (table above). Omit when using `sameas*`. |
| `length` | — | Length (chars for text, precision for numeric). |
| `scale` | — | Decimal places (DECIMAL/AMOUNT). |
| `title` **(req)** | — | UI label. |
| `remarks` **(req)** | — | Description/help. |
| `persistent` | `true` | `false` = non-persistent (computed/virtual) column. |
| `required` | `false` | NOT NULL. On populated tables also needs a default (see below). |
| `defaultvalue` | — | Default value (see special tokens below). |
| `domain` | — | Attach a domain (`domainid`). |
| `classname` | — | Field validation class (`psdi…`/`com.ibm…`). |
| `haslongdesc` | `false` | Has a long-description companion. |
| `mustbe` | `false` | Value must come from the domain. |
| `searchtype` | — | `WILDCARD\|EXACT\|NONE\|TEXT`. |
| `localizable` | — | `true` for translatable text (needs an `L_` language table). |
| `sameasobject` / `sameasattribute` | — | Inherit type/length from an existing column. |
| `canautonum` / `autokey` | `false` / — | Auto-numbering support / seed name. |
| `ispositive` | `false` | Numeric must be ≥ 0. |
| `userdefined` | `false` | Marks a user-added attribute. |
| `restricted` | — | Restricted attribute. |
| `domainlink` | — | Column that qualifies the domain lookup. |

`<modify_attribute>` accepts the same attributes (plus `object`, `attribute` required, and
`excludetenants`); pass only what you are changing.

### `defaultvalue` special tokens
Seen in `RequiredColumnDefaults.txt`; also valid as `defaultvalue`:
- `&USERNAME&` — current user
- `&SYSDATE&` / `&sysdate&` — current date/time
- `!VALUE!` — the domain's default synonym for the attribute (e.g. `!WAPPR!`)
- literals: `0`, `1`, `MAXADMIN`, … (`&AUTOKEY&` is **not** supported)

## Required columns on populated tables — `RequiredColumnDefaults.txt`

Adding a `required="true"` column to a table that already has rows will fail unless existing rows can
be back-filled. Two ways to supply the back-fill value:
1. Put `defaultvalue="…"` on the `<attrdef>` (simplest), or
2. Add a line to `RequiredColumnDefaults.txt`:
   ```
   // <table>,<column>,<default value>   (rest of line after 2nd comma is the value; no inline comments)
   WORKTYPE, KEEPTASKSTATUSHIST, 1
   ReportDesign, ImportedDate, &sysdate&
   ```
   (`!MaxValue!` converts to the attribute's default domain synonym.)

Location: `MANAGE/SMP/maximo/tools/maximo/en/script/RequiredColumnDefaults.txt`.

## `<columnvalue>` value-type attributes (for insert/update/delete)

Set exactly one value-type per `columnvalue` (besides `column`). Ordered by real-world frequency in
the shipped scripts:

| Attribute | Use for |
|-----------|---------|
| `string` | Text/char value (by far the most common). |
| `boolean` | `true`/`false` → 1/0 (YORN columns). |
| `number` | Numeric literal. |
| `date` | Date literal (optionally with `offset_days`/`offset_hours`). |
| `selectnumber` | Numeric from a subselect. |
| `fromcolumn` | Copy from another column (insert-from-select context). |
| `domainvalue` + `domainid` | DB-appropriate value resolved from a domain. |
| `selectstring` | String from a subselect. |
| `defaultsynonym` | Default synonym of a domain. |
| `clob` / `blob` | Large-object value. |
| `offset_days` / `offset_hours` | Adjust a `date` value. |

```xml
<insertrow>
  <columnvalue column="app"        string="MXAPIASSET"/>
  <columnvalue column="active"     boolean="true"/>
  <columnvalue column="priority"   number="5"/>
  <columnvalue column="changedate" date="&sysdate&"/>
</insertrow>
```

In `<update>`, `<set>` holds the SET `columnvalue`s and `<where>` holds equality `columnvalue`s
(ANDed); use `<whereclause value="…"/>` for anything beyond simple equality.
