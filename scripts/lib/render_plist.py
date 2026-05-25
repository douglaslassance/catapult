#!/usr/bin/env python3
"""Render Info.plist files for direct distribution or App Store builds.

Two modes:
  - Generated (default): build the plist from trigger.toml fields.
  - Passthrough: `[plist] template = "Info.plist"` — read the app's committed
    plist as the base, inject version + signing/sparkle/appstore keys, and
    preserve every other key (document types, UTI declarations, etc.).

Usage:
  render_plist.py <config> --kind direct|appstore|resource \\
                  --version <v> --build-number <n> [--out <path>]
"""
import argparse
import os
import plistlib
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


def render_resource(cfg: dict, version: str) -> str:
    app = cfg["app"]
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>{xml_escape(app['bundle_id'])}.resources</string>
    <key>CFBundleName</key>
    <string>{xml_escape(app['name'])}_{xml_escape(cfg['build']['swift_target'])}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>{xml_escape(version)}</string>
    <key>CFBundleVersion</key>
    <string>{xml_escape(version)}</string>
</dict>
</plist>
"""


def render_generated(cfg: dict, kind: str, version: str, build_number: str) -> str:
    app = cfg["app"]
    name = app["name"]
    bundle_id = app["bundle_id"]
    min_macos = app["min_macos"]
    category = app.get("category", "")

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
        "    <key>CFBundleExecutable</key>",
        f"    <string>{xml_escape(cfg.get('build', {}).get('executable', name))}</string>",
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


def render_passthrough(cfg: dict, kind: str, version: str, build_number: str,
                       template_path: str, app_root: str) -> str:
    """Read template plist, inject dynamic keys, write back as XML.

    Only the keys that *must* change per build are written; everything else in
    the template (document types, UTI declarations, custom Info.plist keys)
    is preserved as-is.
    """
    full_template_path = template_path if os.path.isabs(template_path) else os.path.join(app_root, template_path)
    with open(full_template_path, "rb") as f:
        plist = plistlib.load(f)

    plist["CFBundleShortVersionString"] = version
    plist["CFBundleVersion"] = build_number

    # Strip Sparkle keys when building for App Store (they're a rejection trigger).
    if kind == "appstore":
        for k in list(plist.keys()):
            if k.startswith("SU") and k[2:3].isupper():
                del plist[k]
        if "appstore" in cfg:
            plist["ITSAppUsesNonExemptEncryption"] = cfg["appstore"].get("non_exempt_encryption", False)
        if cfg.get("app", {}).get("category"):
            plist["LSApplicationCategoryType"] = cfg["app"]["category"]

    if kind == "direct" and "sparkle" in cfg:
        plist["SUFeedURL"] = cfg["sparkle"]["feed_url"]
        plist["SUPublicEDKey"] = os.environ.get("SPARKLE_PUBLIC_KEY", "")

    return plistlib.dumps(plist).decode("utf-8")


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
    app_root = os.path.dirname(os.path.abspath(args.config))

    if args.kind == "resource":
        content = render_resource(cfg, args.version)
    else:
        template = cfg.get("plist", {}).get("template")
        if template:
            content = render_passthrough(cfg, args.kind, args.version, build_number,
                                          template, app_root)
        else:
            content = render_generated(cfg, args.kind, args.version, build_number)

    if args.out:
        with open(args.out, "w") as f:
            f.write(content)
    else:
        sys.stdout.write(content)


if __name__ == "__main__":
    main()
