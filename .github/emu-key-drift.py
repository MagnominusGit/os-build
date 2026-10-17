#!/usr/bin/env python3
# emu-key-drift.py — does an emulator's upstream source still know every settings key RetroForge
# writes for it? (plan emulator-latest, Phase 4; run weekly by .github/workflows/emu-key-drift.yml)
#
#     emu-key-drift.py keys   <emulator data dir>                  -> JSON: every key we write
#     emu-key-drift.py ref    <emu-sources.json> <emulator> <tag>  -> "<owner/repo> <ref>" to fetch
#     emu-key-drift.py check  <emulator data dir> <source tree> [<emu-sources.json> <emulator>]
#                                                                   -> JSON: {"checked", "missing"}
#
# WHY. Emulators install upstream's newest release by default, so a key renamed upstream makes a
# first-run seed or an options.json choice silently do nothing: the emulator ignores what it does
# not know, no error anywhere. This is the only check for it.
#
# HOW. The keys are every `key` an options.json choice sets, plus every key of the first-run seeds
# in the emulator's data dir (ini/cfg/conf, toml, yml, xml). A key counts as known when its text
# appears, case-sensitively, in the upstream source (C/C++/Rust/Python/... files): emulators spell
# their config keys as string literals. Not found = reported. A key upstream builds at run time
# is matched the ways upstreams build them: without its trailing digits (ISOPath0 from "ISOPath" + n),
# one '/' segment at a time (Dolphin's "IR/Up" = group "IR" + control "Up"), or against a printf
# format in the source (mGBA's "axisDownAxis" from "axis%sAxis"). A Qt "<key>\\default" flag is
# its key. Anything else that cannot be found by its text goes in emu-sources.json's "ignore" for
# that emulator, with why.
import json
import os
import re
import sys

SEED_SKIP = {"emulator.json", "options.json"}
SEED_EXT = {".ini", ".cfg", ".conf", ".toml", ".yml", ".yaml", ".xml"}
SOURCE_EXT = {".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx", ".inl", ".inc", ".ipp",
              ".rs", ".py", ".m", ".mm", ".java", ".kt", ".cs", ".ui", ".xml", ".json", ".toml",
              ".yml", ".yaml", ".ini", ".cfg", ".def", ".in", ".txt", ".js"}
SOURCE_MAX = 4 << 20  # bytes per source file read (generated blobs are skipped)


def seed_keys(path):
    """The keys a seed file sets: names left of '=' / ':', or XML element names."""
    ext = os.path.splitext(path)[1].lower()
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    if ext == ".xml":
        text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
        return sorted(set(re.findall(r"<([A-Za-z_][\w.-]*)[\s/>]", text)))
    keys = set()
    yaml = ext in (".yml", ".yaml")
    sep = ":" if yaml else "="
    for line in text.splitlines():
        s = line.strip()
        if not s or s[0] in ";#[" or s.startswith("- ") or sep not in s:
            continue
        key = s.split(sep, 1)[0].strip().strip('"')
        if key:
            keys.add(key)
    return sorted(keys)


def base_key(key):
    """Azahar's Qt ini: "layout_option\\default=false" is the default flag of layout_option."""
    return key.split("\\", 1)[0]


def written_keys(data_dir):
    """{key: [files that write it]} for one emulator's data dir."""
    found = {}
    for name in sorted(os.listdir(data_dir)):
        path = os.path.join(data_dir, name)
        if name in SEED_SKIP or not os.path.isfile(path) or os.path.splitext(name)[1].lower() not in SEED_EXT:
            continue
        for k in seed_keys(path):
            files = found.setdefault(base_key(k), [])
            if name not in files:
                files.append(name)
    opts = os.path.join(data_dir, "options.json")
    if os.path.isfile(opts):
        with open(opts) as f:
            for option in json.load(f).get("options", []):
                for choice in option.get("choices", []):
                    for s in choice.get("set", []):
                        files = found.setdefault(base_key(s["key"]), []) if isinstance(s.get("key"), str) else None
                        if files is not None and "options.json" not in files:
                            files.append("options.json")
    return found


def source_text(tree):
    parts = []
    for root, dirs, files in os.walk(tree):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in files:
            path = os.path.join(root, name)
            if os.path.splitext(name)[1].lower() not in SOURCE_EXT or os.path.islink(path):
                continue
            try:
                if os.path.getsize(path) <= SOURCE_MAX:
                    with open(path, encoding="utf-8", errors="replace") as f:
                        parts.append(f.read())
            except OSError:
                continue
    return "\n".join(parts)


def printf_formats(text):
    """Every string literal of the source with a %s / %d / %i / %u in it, as a regex."""
    out = []
    for lit in set(re.findall(r'"([^"\n\\%]*(?:%[0-9]*[sdiu][^"\n\\%]*)+)"', text)):
        parts = re.split(r"(%[0-9]*[sdiu])", lit)
        rx = "".join(re.escape(p) if i % 2 == 0 else (".+" if p.endswith("s") else "[0-9]+")
                     for i, p in enumerate(parts))
        if len(re.sub(r"%[0-9]*[sdiu]", "", lit)) >= 3:  # "%s" alone would match anything
            out.append(re.compile(rx))
    return out


def known(key, text, formats):
    if key in text:
        return True
    stem = key.rstrip("0123456789")
    if stem != key and len(stem) >= 3 and stem in text:
        return True
    if "/" in key and all(seg in text for seg in key.split("/") if seg):
        return True
    return any(f.fullmatch(key) for f in formats)


def source_entry(sources, emu):
    with open(sources) as f:
        entry = json.load(f).get(emu)
    if not isinstance(entry, dict):
        raise SystemExit(f"emu-key-drift: no source for {emu} in {sources}")
    return entry


def cmd_ref(sources, emu, tag):
    """The upstream ref a build tag was made from: the entry's "tag" regex, "ref" template."""
    e = source_entry(sources, emu)
    m = re.fullmatch(e["tag"], tag)
    if not m:
        raise SystemExit(f"emu-key-drift: {emu} tag {tag!r} does not match {e['tag']!r}")
    print(f"{e['repo']} {e['ref'].format(*m.groups())}")


def cmd_check(data_dir, tree, sources=None, emu=None):
    ignore = set(source_entry(sources, emu).get("ignore", {})) if sources else set()
    keys = written_keys(data_dir)
    text = source_text(tree)
    if not text:
        raise SystemExit(f"emu-key-drift: no source files under {tree}")
    formats = printf_formats(text)
    missing = [{"key": k, "files": f} for k, f in sorted(keys.items())
               if k not in ignore and not known(k, text, formats)]
    print(json.dumps({"checked": len(keys), "ignored": sorted(ignore & set(keys)), "missing": missing}, indent=1))


def main(argv):
    if len(argv) == 2 and argv[0] == "keys":
        print(json.dumps(written_keys(argv[1]), indent=1, sort_keys=True))
    elif len(argv) == 4 and argv[0] == "ref":
        cmd_ref(*argv[1:])
    elif len(argv) in (3, 5) and argv[0] == "check":
        cmd_check(*argv[1:])
    else:
        raise SystemExit("usage: emu-key-drift.py keys <data dir> | ref <sources> <emu> <tag>"
                         " | check <data dir> <source tree> [<sources> <emu>]")


if __name__ == "__main__":
    main(sys.argv[1:])
