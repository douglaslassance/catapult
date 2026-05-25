#!/usr/bin/env python3
"""Parse catapult.toml and emit shell `export` statements.

Output convention:
  - Scalar values become CATAPULT_<SECTION>_<KEY>=<value> (uppercased).
  - Top-level sections emit CATAPULT_HAS_<SECTION>=1 so scripts can branch
    on channel presence (e.g. [sparkle], [r2], [homebrew], [appstore]).
  - Nested dicts under [plist.usage_descriptions] are intentionally skipped
    here; render_plist.py reads the TOML directly for that.

Requires Python 3.11+ (tomllib).
"""
import sys
import shlex

try:
    import tomllib
except ImportError:
    sys.stderr.write(
        "catapult: tomllib not available — need Python 3.11+ "
        "(brew install python@3.12)\n"
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


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "catapult.toml"
    try:
        with open(path, "rb") as f:
            cfg = tomllib.load(f)
    except FileNotFoundError:
        sys.stderr.write(f"catapult: {path} not found\n")
        sys.exit(1)
    except tomllib.TOMLDecodeError as e:
        sys.stderr.write(f"catapult: invalid TOML in {path}: {e}\n")
        sys.exit(1)

    for section, value in cfg.items():
        if isinstance(value, dict):
            print(f"export CATAPULT_HAS_{section.upper()}=1")

    for path_parts, value in flatten(cfg):
        name = "CATAPULT_" + "_".join(p.upper() for p in path_parts)
        print(f"export {name}={shlex.quote(value)}")


if __name__ == "__main__":
    main()
