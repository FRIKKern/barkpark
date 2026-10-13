#!/usr/bin/env python3
"""plugin-code-in-core census: how much plugin code lives inside core, at a git ref.

RULE (stated so the number can be argued with):
  * The plugin roster is DERIVED: every api/lib/barkpark/plugins/*.ex whose source
    has a line `use Barkpark.Plugin` is a plugin; its domain word is the file's
    basename (bulldocs, tasks, media, ...).
  * A CORE directory is any api/lib/barkpark/<dir> (or api/lib/barkpark/content/<dir>)
    outside api/lib/barkpark/plugins/.
  * PLUGIN CODE IN CORE = a core directory whose name is a plugin domain word, or is
    listed in ALIASES (a domain that lives under another word), PLUS the top-level
    context file of the same name (api/lib/barkpark/<domain>.ex). Counted: .ex files
    and lines.
  * COUPLING = core .ex files (outside plugins/ and outside that directory) that
    name the directory's module namespace.
  * WEB = api/lib/barkpark_web .ex files with a path segment that is a plugin
    domain word or a WEB_ALIASES word, followed by `_`, `/` or `.ex`.

Usage: scripts/plugin-code-in-core-census.py [--ref origin/main] [--json]
"""
import json
import re
import subprocess
import sys

ALIASES = {"papers": "bulldocs", "content/papers": "bulldocs"}
WEB_ALIASES = {"paper": "bulldocs", "papers": "bulldocs", "onix": "onixedit"}


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout


def main():
    ref = "origin/main"
    as_json = "--json" in sys.argv
    if "--ref" in sys.argv:
        ref = sys.argv[sys.argv.index("--ref") + 1]

    files = git("ls-tree", "-r", "--name-only", ref, "api/lib").splitlines()
    plugins = sorted(
        f.rsplit("/", 1)[1][:-3]
        for f in files
        if re.fullmatch(r"api/lib/barkpark/plugins/[a-z_]+\.ex", f)
        and re.search(r"^\s*use Barkpark\.Plugin\b", git("show", f"{ref}:{f}"), re.M)
    )
    core = [f for f in files if f.endswith(".ex") and not f.startswith("api/lib/barkpark/plugins/")]

    dirs = {}
    for f in core:
        # A directory (api/lib/barkpark/<d>/ or content/<d>/), or the top-level
        # context file api/lib/barkpark/<d>.ex. Not content/<d>.ex: content/forms.ex
        # is Studio form coercion, not the Forms plugin (a name collision).
        m = re.match(r"api/lib/barkpark/(content/[a-z_]+|[a-z_]+)/", f) or re.match(
            r"api/lib/barkpark/([a-z_]+)\.ex$", f
        )
        if not m:
            continue
        d = m.group(1)
        domain = ALIASES.get(d, d.split("/")[-1])
        if domain in plugins:
            dirs.setdefault(d, {"plugin": domain, "files": []})["files"].append(f)

    rows = []
    for d, info in sorted(dirs.items()):
        ns = "Barkpark." + ".".join(p.title().replace("_", "") for p in d.split("/"))
        lines = sum(git("show", f"{ref}:{f}").count("\n") for f in info["files"])
        pat = re.compile(re.escape(ns) + r"\b")
        callers = [
            f
            for f in core
            if not (f.startswith(f"api/lib/barkpark/{d}/") or f == f"api/lib/barkpark/{d}.ex")
            and pat.search(git("show", f"{ref}:{f}"))
        ]
        rows.append({"dir": f"api/lib/barkpark/{d}[.ex]", "plugin": info["plugin"], "namespace": ns,
                     "files": len(info["files"]), "lines": lines, "core_callers": len(callers)})

    words = {w: w for w in plugins} | {k: v for k, v in WEB_ALIASES.items() if v in plugins}
    web = {}
    for f in files:
        if not (f.startswith("api/lib/barkpark_web/") and f.endswith(".ex")):
            continue
        for seg in f[len("api/lib/barkpark_web/"):].split("/"):
            hit = next((w for w in words if re.match(re.escape(w) + r"(_|$|\.ex$)", seg)), None)
            if hit:
                web.setdefault(words[hit], []).append(f)
                break
    web_rows = [{"plugin": k, "files": len(v), "lines": sum(git("show", f"{ref}:{f}").count("\n") for f in v)}
                for k, v in sorted(web.items())]

    total = {"files": sum(r["files"] for r in rows) + sum(r["files"] for r in web_rows),
             "lines": sum(r["lines"] for r in rows) + sum(r["lines"] for r in web_rows)}
    if as_json:
        print(json.dumps({"ref": ref, "plugins": plugins, "rows": rows, "web": web_rows, "total": total}, indent=1))
        return
    print(f"plugin-code-in-core census at {ref} ({git('rev-parse', '--short', ref).strip()})")
    print(f"plugins (derived, use Barkpark.Plugin): {len(plugins)}: {' '.join(plugins)}")
    print(f"{'core dir':38} {'plugin':9} {'files':>5} {'lines':>7} {'core callers':>12}")
    for r in rows:
        print(f"{r['dir']:38} {r['plugin']:9} {r['files']:>5} {r['lines']:>7} {r['core_callers']:>12}")
    for r in web_rows:
        print(f"{'api/lib/barkpark_web (' + r['plugin'] + ')':38} {r['plugin']:9} {r['files']:>5} {r['lines']:>7} {'-':>12}")
    print(f"{'TOTAL':38} {'':9} {total['files']:>5} {total['lines']:>7}")


if __name__ == "__main__":
    main()
