#!/usr/bin/env python3
"""Render Info.plist files for direct distribution or App Store builds.

Reads trigger.toml directly (not env vars) so it can handle the nested
[plist.usage_descriptions] table without flattening.

Usage:
  render_plist.py <config> --kind direct|appstore|resource \\
                  --version <v> --build-number <n> [--out <path>]

For --kind resource, only --config and --version are required.
"""
import argparse
import os
import sys

try:
    import tomllib
except ImportError:
    sys.stderr.write("trigger: need Python 3.11+\n")
    sys.exit(1)


def xml_escape(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def render(cfg: dict, kind: str, version: str, build_number: str) -> str:
    app = cfg["app"]
    name = app["name"]
    bundle_id = app["bundle_id"]
    min_macos = app["min_macos"]
    category = app.get("category", "")

    if kind == "resource":
        return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>{xml_escape(bundle_id)}.resources</string>
    <key>CFBundleName</key>
    <string>{xml_escape(name)}_{xml_escape(cfg['build']['swift_target'])}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>{xml_escape(version)}</string>
    <key>CFBundleVersion</key>
    <string>{xml_escape(version)}</string>
</dict>
</plist>
"""

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
        "    <key>CFBundleExecutable</key>",
        f"    <string>{xml_escape(name)}</string>",
        "    <key>CFBundleIdentifier</key>",
        f"    <string>{xml_escape(bundle_id)}</string>",
        "    <key>CFBundleName</key>",
        f"    <string>{xml_escape(name)}</string>",
        "    <key>CFBundlePackageType</key>",
        "    <string>APPL</string>",
        "    <key>CFBundleShortVersionString</key>",
        f"    <string>{xml_escape(version)}</string>",
        "    <key>CFBundleVersion</key>",
        f"    <string>{xml_escape(build_number)}</string>",
        "    <key>CFBundleIconFile</key>",
        "    <string>AppIcon</string>",
        "    <key>LSMinimumSystemVersion</key>",
        f"    <string>{xml_escape(min_macos)}</string>",
        "    <key>NSHighResolutionCapable</key>",
        "    <true/>",
    ]

    if category and kind == "appstore":
        lines += [
            "    <key>LSApplicationCategoryType</key>",
            f"    <string>{xml_escape(category)}</string>",
        ]

    # Usage descriptions
    usage = cfg.get("plist", {}).get("usage_descriptions", {}) or {}
    for k, v in usage.items():
        lines += [
            f"    <key>{xml_escape(k)}</key>",
            f"    <string>{xml_escape(str(v))}</string>",
        ]

    if kind == "direct" and "sparkle" in cfg:
        feed_url = cfg["sparkle"]["feed_url"]
        public_key = os.environ.get("SPARKLE_PUBLIC_KEY", "")
        lines += [
            "    <key>SUFeedURL</key>",
            f"    <string>{xml_escape(feed_url)}</string>",
            "    <key>SUPublicEDKey</key>",
            f"    <string>{xml_escape(public_key)}</string>",
        ]

    if kind == "appstore":
        non_exempt = cfg.get("appstore", {}).get("non_exempt_encryption", False)
        lines += [
            "    <key>ITSAppUsesNonExemptEncryption</key>",
            f"    <{'true' if non_exempt else 'false'}/>",
        ]

    # Arbitrary extra Info.plist keys, applied to all kinds. Supports string,
    # bool, int. (More exotic types: extend here.)
    extras = cfg.get("plist", {}).get("extras", {}) or {}
    for k, v in extras.items():
        lines.append(f"    <key>{xml_escape(k)}</key>")
        if isinstance(v, bool):
            lines.append(f"    <{'true' if v else 'false'}/>")
        elif isinstance(v, int):
            lines.append(f"    <integer>{v}</integer>")
        else:
            lines.append(f"    <string>{xml_escape(str(v))}</string>")

    lines += ["</dict>", "</plist>", ""]
    return "\n".join(lines)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("config")
    p.add_argument("--kind", required=True, choices=["direct", "appstore", "resource"])
    p.add_argument("--version", required=True)
    p.add_argument("--build-number", default="")
    p.add_argument("--out")
    args = p.parse_args()

    with open(args.config, "rb") as f:
        cfg = tomllib.load(f)

    build_number = args.build_number or args.version
    content = render(cfg, args.kind, args.version, build_number)

    if args.out:
        with open(args.out, "w") as f:
            f.write(content)
    else:
        sys.stdout.write(content)


if __name__ == "__main__":
    main()
