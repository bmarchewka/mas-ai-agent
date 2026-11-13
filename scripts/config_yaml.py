#!/usr/bin/env python3
"""config_yaml.py — dependency-free reader/writer for mas-agent's config.yaml.

Used by scripts/config-lib.sh when the mikefarah `yq` binary is not available.
Only the YAML subset that config.yaml uses is supported: nested block maps,
block lists, flow lists ([A, B]), quoted/unquoted scalars and # comments.

Usage:
  config_yaml.py get  CONFIG KEY [KEY ...]   -> scalar value ("" if absent/null)
  config_yaml.py list CONFIG KEY [KEY ...]   -> one item per line; a scalar is
                                                split on commas; absent -> none
  config_yaml.py keys CONFIG KEY [KEY ...]   -> keys of a map, one per line
  config_yaml.py rows CONFIG KEY [KEY ...]   -> every leaf below KEY as
                                                key1<TAB>key2<TAB>...<TAB>value
                                                (path relative to the document root)
  config_yaml.py write-status CONFIG         -> replace the top-level `status:` block
                                                with the leaves given on stdin, one per
                                                line: key<TAB>key<TAB>...<TAB>value
                                                (paths relative to `status`)
"""
import re
import sys

KEY_RE = re.compile(r"""^("[^"]*"|'[^']*'|[^:#]+?)\s*:(?:\s+(.*))?$""")


def strip_comment(text):
    """Drop a trailing ' # comment' that is not inside quotes."""
    quote = None
    for i, ch in enumerate(text):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "#" and (i == 0 or text[i - 1].isspace()):
            return text[:i].rstrip()
    return text.rstrip()


def unquote(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        return s[1:-1]
    return s


def parse_scalar(raw):
    raw = raw.strip()
    if raw == "" or raw in ("~", "null"):
        return None
    if raw.startswith("[") and raw.endswith("]"):
        return [unquote(p) for p in raw[1:-1].split(",") if p.strip()]
    return unquote(raw)


def load(path):
    with open(path) as f:
        raw_lines = f.read().splitlines()
    lines = []
    for line in raw_lines:
        text = strip_comment(line)
        if not text.strip():
            continue
        indent = len(text) - len(text.lstrip(" "))
        lines.append((indent, text.strip()))

    def parse_block(i, indent):
        if lines[i][1].startswith("- ") or lines[i][1] == "-":
            items = []
            while i < len(lines) and lines[i][0] == indent and lines[i][1].startswith("-"):
                items.append(parse_scalar(lines[i][1][1:]))
                i += 1
            return items, i
        result = {}
        while i < len(lines) and lines[i][0] == indent:
            m = KEY_RE.match(lines[i][1])
            if not m:
                i += 1
                continue
            key, rest = unquote(m.group(1)), (m.group(2) or "")
            i += 1
            if rest.strip():
                result[key] = parse_scalar(rest)
            elif i < len(lines) and lines[i][0] > indent:
                result[key], i = parse_block(i, lines[i][0])
            elif i < len(lines) and lines[i][0] == indent and lines[i][1].startswith("-"):
                # YAML allows a block list at the same indent as its key.
                result[key], i = parse_block(i, indent)
            else:
                result[key] = None
        return result, i

    if not lines:
        return {}
    data, _ = parse_block(0, lines[0][0])
    return data if isinstance(data, dict) else {}


def lookup(data, keys):
    node = data
    for k in keys:
        if not isinstance(node, dict) or k not in node:
            return None
        node = node[k]
    return node


def cmd_get(config, keys):
    val = lookup(load(config), keys)
    if val is None or isinstance(val, (dict, list)):
        return
    print(val)


def cmd_list(config, keys):
    val = lookup(load(config), keys)
    if val is None:
        return
    items = val if isinstance(val, list) else str(val).split(",")
    for item in items:
        if item is not None and str(item).strip():
            print(str(item).strip())


def cmd_keys(config, keys):
    val = lookup(load(config), keys)
    if isinstance(val, dict):
        for k in val:
            print(k)


def cmd_rows(config, keys):
    def walk(node, path):
        if isinstance(node, dict):
            for k, v in node.items():
                walk(v, path + [k])
        elif node is not None and not isinstance(node, list):
            print("\t".join(path + [str(node)]))

    walk(lookup(load(config), keys), list(keys))


def _yaml_key(k):
    return f'"{k}"' if re.search(r"^[\d.]+$|[:#\s]", k) else k


def cmd_write_status(config):
    tree = {}
    for line in sys.stdin.read().splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            sys.exit(f"ERROR: malformed status row: {line!r}")
        node = tree
        for k in parts[:-2]:
            node = node.setdefault(k, {})
        node[parts[-2]] = parts[-1]

    block = ["status:\n"]

    def emit(node, indent):
        for k, v in node.items():
            if isinstance(v, dict):
                block.append(f"{'  ' * indent}{_yaml_key(k)}:\n")
                emit(v, indent + 1)
            else:
                block.append(f'{"  " * indent}{_yaml_key(k)}: "{v}"\n')

    if tree:
        emit(tree, 1)
    else:
        block = ["status: {}\n"]

    with open(config) as f:
        lines = f.readlines()

    out, i, replaced = [], 0, False
    while i < len(lines):
        if re.match(r"^status\s*:", lines[i]):
            out.extend(block)
            replaced = True
            i += 1
            # Skip the old block: indented, blank or comment lines until the
            # next top-level key.
            while i < len(lines) and not re.match(r"^[^\s#]", lines[i]):
                i += 1
            continue
        out.append(lines[i])
        i += 1

    if not replaced:
        if out and not out[-1].endswith("\n"):
            out[-1] += "\n"
        out.append("# !! SECTION STATUS WAS AUTO-GENERATED — do not edit manually !!\n")
        out.append("# Populated by scripts/mas-manage-resolve-image.sh (step 2).\n")
        out.extend(block)

    with open(config, "w") as f:
        f.writelines(out)


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    cmd, config, keys = argv[1], argv[2], argv[3:]
    if cmd == "get":
        cmd_get(config, keys)
    elif cmd == "list":
        cmd_list(config, keys)
    elif cmd == "keys":
        cmd_keys(config, keys)
    elif cmd == "rows":
        cmd_rows(config, keys)
    elif cmd == "write-status":
        cmd_write_status(config)
    else:
        sys.exit(f"ERROR: unknown command {cmd!r}")


if __name__ == "__main__":
    main(sys.argv)
