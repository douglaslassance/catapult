#!/usr/bin/env python3
"""Parse catapult.toml and emit shell `export` statements.

Output convention:
  - Scalar values become CATAPULT_<SECTION>_<KEY>=<value> (uppercased).
  - Top-level sections emit CATAPULT_HAS_<SECTION>=1 so scripts can branch
    on channel presence (e.g. [sparkle], [s3], [homebrew], [appstore]).
  - Nested dicts under [plist.usage_descriptions] are intentionally skipped
    here; render_plist.py reads the TOML directly for that.
  - A config with [targets.<name>] tables describes several apps in one repo.
    CATAPULT_TARGET picks one, and its tables are merged over the shared ones.

Requires Python 3.11+ (tomllib).
"""

import os
import sys
import shlex

try:
    import tomllib
except ImportError:
    sys.stderr.write(
        "catapult: tomllib not available — need Python 3.11+ (brew install python@3.12)\n"
    )
    sys.exit(1)


SKIP_PATHS = {("plist", "usage_descriptions")}


def flatten(d, prefix=()):
    for k, v in d.items():
        path = prefix + (k,)
        if path in SKIP_PATHS:
            continue
        if isinstance(v, dict):
            yield from flatten(v, path)
        elif isinstance(v, bool):
            yield path, "1" if v else "0"
        elif isinstance(v, list):
            yield path, " ".join(str(x) for x in v)
        else:
            yield path, str(v)


def merge(base, override):
    merged = dict(base)
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(merged.get(k), dict):
            merged[k] = merge(merged[k], v)
        else:
            merged[k] = v
    return merged


def fail(message):
    sys.stderr.write(f"catapult: {message}\n")
    sys.exit(1)


def load_config(path, target=None):
    """The config at path, with the target's tables merged over the shared ones."""
    try:
        with open(path, "rb") as f:
            cfg = tomllib.load(f)
    except FileNotFoundError:
        fail(f"{path} not found")
    except tomllib.TOMLDecodeError as e:
        fail(f"invalid TOML in {path}: {e}")

    targets = cfg.pop("targets", None)
    if targets is None:
        if target:
            fail(f"{path} has no [targets], so there is no target {target!r}")
        return cfg
    names = ", ".join(targets)
    if not target:
        fail(f"{path} has several targets ({names}); pass --target or set CATAPULT_TARGET")
    if target not in targets:
        fail(f"{path} has no target {target!r} (it has {names})")
    return merge(cfg, targets[target])


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "catapult.toml"
    cfg = load_config(path, os.environ.get("CATAPULT_TARGET"))

    # Windows Python writes CRLF in the ANSI code page, and bash would eval the stray \r into every value.
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")

    for section, value in cfg.items():
        if isinstance(value, dict):
            print(f"export CATAPULT_HAS_{section.upper()}=1")

    for path_parts, value in flatten(cfg):
        name = "CATAPULT_" + "_".join(p.upper() for p in path_parts)
        print(f"export {name}={shlex.quote(value)}")


if __name__ == "__main__":
    main()
