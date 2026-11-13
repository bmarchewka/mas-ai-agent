#!/usr/bin/env python3
"""catalog_resolve.py — resolve Manage / MAS core versions in an operator catalog.

Works on the OLM file-based catalog folders copied out of the IBM Maximo
Operator Catalog image (stdlib only, no PyYAML):

  <root>/ibm-mas-manage/   package.yaml, channel-*.yaml, objects/<bundle>.yaml
  <root>/ibm-mas/          (MAS core — supplies the graphite-configuration image)

A bundle is *selectable* when its relatedImages contain the image we extract
(manage/manageadmin for Manage, mas/graphite-configuration for core), or when
they at least contain the bundle's operator image (icr.io/cpopen/ibm-mas-manage
or icr.io/cpopen/ibm-mas). Older catalogs (and older patch bundles in newer
ones) list only the operator images; for those the image is reported as
`trace:<operator image>` and mas-manage-resolve-image.sh reads the pinned image
digest out of the operator images themselves (see `lookup`). MAS core <= 9.0
has no Graphite at all, so those core versions are listed but never selectable.

Version specs (per item of config.yaml catalog.operators.<tag>.manage / .core):
  latest         newest selectable bundle in the package's defaultChannel
  9.2.x | 9.2    newest selectable bundle in channel 9.2.x
  9.3.x-feature  any channel name works the same way
  9.2.4          that exact bundle version (ibm-mas-manage.v9.2.4)

Usage:
  catalog_resolve.py list    ROOT
  catalog_resolve.py resolve ROOT KIND SPEC [SPEC ...]     KIND = manage | core
      prints one TSV row per spec:
        OK<TAB>kind<TAB>requested<TAB>version<TAB>channel<TAB>bundle<TAB>image
        ERROR<TAB>kind<TAB>requested<TAB>message
        SKIP<TAB>kind<TAB>requested<TAB>message   (core <= 9.0: no Graphite exists)
      image is either the image reference or trace:<operator image>.
      exit code 1 if any spec failed.
  catalog_resolve.py lookup FILE map MAPNAME KEY
      FILE is an operator vars file (supported-images.yml); prints the value of
      supportedImages.<MAPNAME>.<KEY> (a digest).
  catalog_resolve.py lookup FILE image KEY
      FILE is an operator images-with-digests.yml; prints
      digest<TAB>tag<TAB>name of images.<KEY> (tag from digest_info, may be empty).
      exit code 1 when not found.
"""
import os
import re
import sys

PACKAGES = {
    "manage": ("ibm-mas-manage", "manage/manageadmin:", "manageadmin"),
    "core": ("ibm-mas", "mas/graphite-configuration:", "graphite"),
}

# The bundle's operator image, used to trace the image when relatedImages lacks it.
OPERATOR_IMAGES = {
    "manage": "icr.io/cpopen/ibm-mas-manage@",
    "core": "icr.io/cpopen/ibm-mas@",
}

# MAS core releases older than this ship no Graphite (graphite-configuration).
CORE_MIN_GRAPHITE = (9, 1)


class Skip(ValueError):
    """The requested version range has nothing to extract by design (not an error)."""


def version_key(version):
    """Sort key: numeric parts first; a pre-release sorts before its release."""
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)(.*)$", version)
    if not m:
        return (0, 0, 0, 0, version)
    major, minor, patch, rest = int(m[1]), int(m[2]), int(m[3]), m[4]
    return (major, minor, patch, 0 if rest else 1, rest)


def channel_key(name):
    return [int(p) if p.isdigit() else p for p in re.split(r"(\d+)", name)]


def image_build(image):
    """cp.icr.io/cp/manage/manageadmin:9.2.265-amd64@sha256:... -> 9.2.265"""
    tag = image.split("@")[0].rsplit(":", 1)[-1]
    return re.sub(r"-(amd64|arm64|ppc64le|s390x)$", "", tag)


class Package:
    def __init__(self, root, kind):
        self.kind = kind
        self.name, self.prefix, self.image_label = PACKAGES[kind]
        self.dir = os.path.join(root, self.name)
        if not os.path.isdir(self.dir):
            raise SystemExit(f"ERROR: catalog folder {self.dir} not found")
        self.default_channel = None
        pkg = os.path.join(self.dir, "package.yaml")
        if os.path.isfile(pkg):
            m = re.search(r"^defaultChannel:\s*(\S+)", open(pkg).read(), re.M)
            self.default_channel = m[1].strip("'\"") if m else None

        # channel name -> [bundle names in file order]
        self.channels = {}
        for fname in os.listdir(self.dir):
            if not (fname.startswith("channel") and fname.endswith(".yaml")):
                continue
            text = open(os.path.join(self.dir, fname)).read()
            m = re.search(r"^name:\s*(\S+)", text, re.M)
            if not m:
                continue
            entries = re.findall(r"^-\s+name:\s*(\S+)", text, re.M)
            self.channels[m[1].strip("'\"")] = [e.strip("'\"") for e in entries]

        self._images = {}
        self._operators = {}

    def version_of(self, bundle):
        return bundle[len(self.name) + 2:] if bundle.startswith(self.name + ".v") else bundle

    def image(self, bundle):
        """The extracted image for a bundle, or None if the bundle lacks it."""
        if bundle in self._images:
            return self._images[bundle]
        found = None
        path = os.path.join(self.dir, "objects", bundle + ".yaml")
        if os.path.isfile(path):
            lines = open(path).read().splitlines()
            for i, line in enumerate(lines):
                if re.match(r"^\s+name:\s+" + re.escape(self.prefix), line):
                    for j in range(i - 1, max(i - 3, -1), -1):
                        m = re.match(r"^\s*-?\s*image:\s*(\S+)", lines[j])
                        if m:
                            found = m[1]
                            break
                    break
        self._images[bundle] = found
        return found

    def operator_image(self, bundle):
        """The bundle's operator image (icr.io/cpopen/<operator>@sha256:...), or None."""
        if bundle in self._operators:
            return self._operators[bundle]
        found = None
        path = os.path.join(self.dir, "objects", bundle + ".yaml")
        if os.path.isfile(path):
            prefix = re.escape(OPERATOR_IMAGES[self.kind])
            m = re.search(r"^\s*-?\s*image:\s*(" + prefix + r"sha256:[0-9a-f]{64})\s*$",
                          open(path).read(), re.M)
            found = m[1] if m else None
        self._operators[bundle] = found
        return found

    def traceable(self, version):
        """False for MAS core versions (or channels such as 9.0.x) older than 9.1."""
        if self.kind == "core":
            m = re.match(r"^(\d+)\.(\d+)(\.|$)", version)
            if not m or (int(m[1]), int(m[2])) < CORE_MIN_GRAPHITE:
                return False
        return True

    def candidate(self, bundle):
        """The image for a bundle: listed image, trace:<operator image>, or None."""
        img = self.image(bundle)
        if img:
            return img
        op = self.operator_image(bundle)
        if op and self.traceable(self.version_of(bundle)):
            return "trace:" + op
        return None

    def selectable(self, channel):
        """[(version, bundle, image)] newest first, only bundles with a usable image."""
        out = []
        for bundle in self.channels.get(channel, []):
            img = self.candidate(bundle)
            if img:
                out.append((self.version_of(bundle), bundle, img))
        out.sort(key=lambda r: version_key(r[0]), reverse=True)
        return out

    def no_image_reason(self, channel=None):
        if self.kind == "core" and channel and not self.traceable(channel):
            return ("MAS core <= 9.0 ships no Graphite (graphite-configuration); Manage <= 9.0 "
                    "Graphite apps still come from its SMP folder")
        return f"no {self.image_label} image or {self.name} operator image in this catalog"

    def channel_of(self, bundle):
        for name, entries in self.channels.items():
            if bundle in entries:
                return name
        return None

    def sorted_channels(self):
        return sorted(self.channels, key=channel_key, reverse=True)

    def describe_channel(self, channel, limit=8):
        rows = self.selectable(channel)
        if not rows:
            return f"channel {channel} has no selectable {self.name} version ({self.no_image_reason(channel)})"
        shown = ", ".join(r[0] for r in rows[:limit])
        more = f" (+{len(rows) - limit} older)" if len(rows) > limit else ""
        return f"selectable in {channel}: {shown}{more}"

    def resolve(self, spec):
        """-> (version, channel, bundle, image) or raises ValueError."""
        spec = spec.strip()
        low = spec.lower()
        if low in ("", "latest"):
            if not self.default_channel:
                raise ValueError(f"{self.name} has no defaultChannel")
            channel = self.default_channel
        elif spec in self.channels:
            channel = spec
        elif re.match(r"^\d+\.\d+(\.x)?$", low) and (re.sub(r"(\.x)?$", ".x", low, count=1) in self.channels):
            channel = re.sub(r"(\.x)?$", ".x", low, count=1)
        else:
            channel = None

        if channel is not None:
            rows = self.selectable(channel)
            if not rows:
                if not self.traceable(channel):
                    raise Skip(self.describe_channel(channel))
                raise ValueError(self.describe_channel(channel))
            version, bundle, img = rows[0]
            return version, channel, bundle, img

        # Exact version.
        bundle = f"{self.name}.v{spec}"
        channel = self.channel_of(bundle)
        if channel is None:
            chans = ", ".join(self.sorted_channels())
            raise ValueError(f"{self.name} version '{spec}' is not in this catalog (channels: {chans})")
        img = self.candidate(bundle)
        if not img and not self.traceable(spec):
            raise Skip(f"{bundle}: " + self.no_image_reason(spec))
        if not img:
            reason = self.no_image_reason(spec) if not self.traceable(spec) else \
                f"has no {self.image_label} image or operator image in this catalog"
            raise ValueError(f"{bundle} is listed in channel {channel} but {reason}; "
                             + self.describe_channel(channel))
        return spec, channel, bundle, img


def cmd_list(root):
    for kind in ("manage", "core"):
        pkg = Package(root, kind)
        print(f"{pkg.name}  ({kind}: {pkg.image_label} image)  defaultChannel: {pkg.default_channel}")
        latest = None
        try:
            latest = pkg.resolve("latest")[2]
        except ValueError:
            pass
        for channel in pkg.sorted_channels():
            rows = pkg.selectable(channel)
            total = len(pkg.channels[channel])
            label = f"  {channel:<15} {len(rows):>2}/{total:<2} selectable"
            if not rows:
                print(f"{label}   — none ({pkg.no_image_reason(channel)})")
                continue
            items = []
            for version, bundle, img in rows:
                mark = " ← latest" if bundle == latest else ""
                build = "via operator" if img.startswith("trace:") else image_build(img)
                items.append(f"{version} ({build}){mark}")
            print(f"{label}   " + ", ".join(items))
        print()


def cmd_resolve(root, kind, specs):
    if kind not in PACKAGES:
        raise SystemExit(f"ERROR: kind must be manage or core, not {kind!r}")
    pkg = Package(root, kind)
    failed = False
    for spec in specs:
        try:
            version, channel, bundle, img = pkg.resolve(spec)
            print("\t".join(["OK", kind, spec, version, channel, bundle, img]))
        except Skip as exc:
            print("\t".join(["SKIP", kind, spec, str(exc)]))
        except ValueError as exc:
            failed = True
            print("\t".join(["ERROR", kind, spec, str(exc)]))
    return 1 if failed else 0


def _blocks(lines, parent):
    """Children (2-space keys) of the top-level key `parent`: {key: [lines]}."""
    out, cur, inside = {}, None, False
    for line in lines:
        if re.match(r"^\S", line):
            inside = re.match(r"^" + re.escape(parent) + r":\s*$", line) is not None
            cur = None
            continue
        if not inside:
            continue
        m = re.match(r"^  ['\"]?([^'\"\s:][^'\":]*?)['\"]?:\s*(.*)$", line)
        if m:
            cur = m[1]
            out[cur] = [m[2]] if m[2] else []
        elif cur is not None:
            out[cur].append(line)
    return out


def _norm(version):
    return re.sub(r"[+_]", "-", version.strip())


def cmd_lookup(path, mode, args):
    lines = open(path).read().splitlines()
    if mode == "map" and len(args) == 2:
        block = _blocks(lines, "supportedImages").get(args[0], [])
        for line in block:
            m = re.match(r"^\s+['\"]?([^'\":]+?)['\"]?:\s*['\"]?(sha256:[0-9a-f]{64})", line)
            # OLM bundle versions use "-" where the operator writes "+" / "_"
            # (9.1.0-pre.stable-9992 vs 9.1.0-pre.stable+9992).
            if m and _norm(m[1]) == _norm(args[1]):
                print(m[2])
                return 0
        return 1
    if mode == "image" and len(args) == 1:
        block = _blocks(lines, "images").get(args[0])
        if block is None:
            return 1
        digest = name = ""
        tags = []
        in_info = False
        for line in block:
            m = re.match(r"^    (\w+):\s*(.*)$", line)
            if m:
                in_info = m[1] == "digest_info"
                val = m[2].strip().strip("'\"")
                if m[1] == "digest":
                    digest = val
                elif m[1] == "name":
                    name = val
                continue
            m = re.match(r"^      ['\"]?([^'\":]+?)['\"]?:\s*['\"]?(sha256:[0-9a-f]{64})", line)
            if in_info and m:
                tags.append((m[1], m[2]))
        if not digest and tags:
            digest = tags[0][1]
        if not re.match(r"^sha256:[0-9a-f]{64}$", digest):
            return 1
        tag = next((t for t, d in tags if d == digest), "")
        print("\t".join([digest, tag, name]))
        return 0
    raise SystemExit(__doc__)


def main(argv):
    if len(argv) >= 4 and argv[1] == "lookup":
        return cmd_lookup(argv[2], argv[3], argv[4:])
    if len(argv) >= 3 and argv[1] == "list":
        cmd_list(argv[2])
        return 0
    if len(argv) >= 5 and argv[1] == "resolve":
        return cmd_resolve(argv[2], argv[3], argv[4:])
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
