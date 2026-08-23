#!/usr/bin/env python3
"""Drive the App Store Connect TestFlight steps that follow an .ipa upload.

Uploading puts a build in App Store Connect, but external testers can't see it
until three more things happen: the build finishes processing, it has "What to
Test" text, and it passes Beta App Review. Apple only auto-approves later builds
within an already-reviewed version train, and catapult mints a fresh marketing
version per release, so every release needs this. That makes it worth
automating rather than clicking through.

Auth reuses the App Store Connect API key catapult already needs for notarizing
and uploading (NOTARIZATION_KEY / _KEY_ID / _ISSUER_ID). Signing the JWT is
delegated to `openssl` so this stays on the standard library; the only work left
here is reshaping openssl's DER signature into the raw r||s form JOSE wants.

Note that submitting for Beta App Review needs the key to hold App Manager (or
Admin); an upload-only Developer key gets a 403 on that last step.

Usage:
  testflight_ios.py --config catapult.toml --app-id-fallback-bundle com.example \\
                    --version 1.2.3 --build-number 1786291989 \\
                    --notes-file notes.txt [--timeout 1200]
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import tomllib
except ImportError:
    sys.stderr.write("catapult: need Python 3.11+\n")
    sys.exit(1)

API = "https://api.appstoreconnect.apple.com"
# App Store Connect caps "What to Test" at 4000 characters.
WHATS_NEW_MAX = 4000


class ASCError(RuntimeError):
    pass


# --- auth ---------------------------------------------------------------


def load_private_key() -> str:
    """Return the .p8 PEM, from the env var (raw or base64) or the key dir."""
    key_id = os.environ.get("NOTARIZATION_KEY_ID", "")
    raw = os.environ.get("NOTARIZATION_KEY", "")
    if raw:
        if "BEGIN" in raw:
            return raw
        try:
            return base64.b64decode(raw).decode()
        except Exception as e:
            raise ASCError(f"NOTARIZATION_KEY is neither PEM nor base64 PEM: {e}")
    path = os.path.expanduser(
        f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8"
    )
    if os.path.exists(path):
        with open(path) as f:
            return f.read()
    raise ASCError(
        "No App Store Connect private key. Set NOTARIZATION_KEY (base64 of the "
        f".p8) or place it at {path}"
    )


def b64url(data: bytes) -> bytes:
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def der_to_raw(der: bytes) -> bytes:
    """Convert an ECDSA DER SEQUENCE{INTEGER r, INTEGER s} to raw r||s."""
    if not der or der[0] != 0x30:
        raise ASCError("openssl returned a malformed ECDSA signature")
    i = 2
    if der[1] & 0x80:  # long-form length
        i = 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        if der[i] != 0x02:
            raise ASCError("openssl returned a malformed ECDSA signature")
        length = der[i + 1]
        value = der[i + 2 : i + 2 + length]
        i += 2 + length
        # DER integers are signed, so a leading zero byte may pad a high bit.
        value = value.lstrip(b"\x00")
        if len(value) > 32:
            raise ASCError("ECDSA signature component longer than P-256 allows")
        out += value.rjust(32, b"\x00")
    return out


def make_token() -> str:
    key_id = os.environ.get("NOTARIZATION_KEY_ID")
    issuer = os.environ.get("NOTARIZATION_ISSUER_ID")
    if not key_id or not issuer:
        raise ASCError("NOTARIZATION_KEY_ID and NOTARIZATION_ISSUER_ID required")

    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = b64url(
        json.dumps(
            {"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
        ).encode()
    )
    signing_input = header + b"." + payload

    pem = load_private_key()
    with tempfile.NamedTemporaryFile("w", suffix=".p8", delete=False) as f:
        f.write(pem)
        key_path = f.name
    try:
        os.chmod(key_path, 0o600)
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path, "-binary"],
            input=signing_input,
            capture_output=True,
        )
        if proc.returncode != 0:
            raise ASCError(f"openssl could not sign the JWT: {proc.stderr.decode()}")
        sig = der_to_raw(proc.stdout)
    finally:
        os.unlink(key_path)

    return (signing_input + b"." + b64url(sig)).decode()


# --- transport ----------------------------------------------------------


class Client:
    def __init__(self, dry_run: bool = False):
        self._token = None
        self._minted_at = 0
        self.dry_run = dry_run

    @property
    def token(self) -> str:
        # Tokens last 15 minutes and polling can outlive that, so re-mint.
        if not self._token or time.time() - self._minted_at > 600:
            self._token = make_token()
            self._minted_at = time.time()
        return self._token

    def request(self, method: str, path: str, body=None, **params):
        if self.dry_run and method != "GET":
            print(f"   [dry run] {method} {path}")
            return {}
        url = API + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token)
        if data:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            try:
                errors = json.loads(detail).get("errors", [])
                detail = "; ".join(
                    f"{x.get('title')}: {x.get('detail')}" for x in errors
                ) or detail
            except Exception:
                pass
            raise ASCError(f"{method} {path} -> HTTP {e.code}: {detail}") from None

    def get(self, path, **params):
        return self.request("GET", path, None, **params)

    def post(self, path, body):
        return self.request("POST", path, body)

    def patch(self, path, body):
        return self.request("PATCH", path, body)


# --- steps --------------------------------------------------------------


def find_app(client: Client, bundle_id: str) -> dict:
    res = client.get("/v1/apps", **{"filter[bundleId]": bundle_id, "limit": "2"})
    apps = res.get("data", [])
    if not apps:
        raise ASCError(f"No App Store Connect app with bundle id {bundle_id}")
    return apps[0]


def wait_for_build(
    client: Client, app_id: str, version: str, build_number: str, timeout: int
) -> dict:
    """Poll until the build exists and finishes processing."""
    deadline = time.time() + timeout
    filters = {
        "filter[app]": app_id,
        "filter[version]": build_number,
        "fields[builds]": "version,processingState,expired",
        "limit": "1",
    }
    if version:
        filters["filter[preReleaseVersion.version]"] = version

    announced = False
    while True:
        builds = client.get("/v1/builds", **filters).get("data", [])
        if builds:
            build = builds[0]
            state = build["attributes"]["processingState"]
            if state == "VALID":
                return build
            if state in ("FAILED", "INVALID"):
                raise ASCError(
                    f"Build {build_number} finished processing as {state}. "
                    "Check the email from App Store Connect for the reason."
                )
            if not announced:
                print(f"⏳ Build {build_number} is {state}; waiting…", flush=True)
                announced = True
        elif not announced:
            print(
                f"⏳ Waiting for build {build_number} to appear in App Store Connect…",
                flush=True,
            )
            announced = True

        if time.time() >= deadline:
            raise ASCError(
                f"Timed out after {timeout}s waiting for build {build_number} to "
                "finish processing. The upload itself succeeded — re-run "
                "./catapult/testflight_ios.sh once processing completes."
            )
        time.sleep(30)


def set_whats_new(
    client: Client, build_id: str, locale: str, notes: str, force: bool = False
) -> None:
    notes = notes.strip()[:WHATS_NEW_MAX]
    existing = client.get(f"/v1/builds/{build_id}/betaBuildLocalizations").get(
        "data", []
    )
    match = next(
        (x for x in existing if x["attributes"].get("locale") == locale), None
    )
    if match is None and existing:
        match = existing[0]

    if match:
        current = (match["attributes"].get("whatsNew") or "").strip()
        if current == notes:
            print("✅ What to Test already up to date")
            return
        # A re-run must not clobber notes someone wrote by hand in App Store
        # Connect. Fresh builds have none, so this only bites on re-runs.
        if current and not force:
            print(
                "ℹ️  What to Test already written; keeping it. "
                "Pass --force-notes to replace it with the generated notes."
            )
            return
        client.patch(
            f"/v1/betaBuildLocalizations/{match['id']}",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "id": match["id"],
                    "attributes": {"whatsNew": notes},
                }
            },
        )
    else:
        client.post(
            "/v1/betaBuildLocalizations",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"whatsNew": notes, "locale": locale},
                    "relationships": {
                        "build": {"data": {"type": "builds", "id": build_id}}
                    },
                }
            },
        )
    print(f"✅ Set What to Test ({locale})")


def resolve_groups(client: Client, app_id: str, names: list) -> list:
    res = client.get(
        "/v1/betaGroups",
        **{
            "filter[app]": app_id,
            "fields[betaGroups]": "name,isInternalGroup",
            "limit": "200",
        },
    )
    by_name = {g["attributes"]["name"]: g for g in res.get("data", [])}
    missing = [n for n in names if n not in by_name]
    if missing:
        known = ", ".join(sorted(by_name)) or "(none)"
        raise ASCError(
            f"Beta group(s) not found in App Store Connect: {', '.join(missing)}. "
            f"Known groups: {known}"
        )
    return [by_name[n] for n in names]


def attach_groups(client: Client, build_id: str, groups: list) -> None:
    # The build's betaGroups relationship only allows CREATE/DELETE, so read the
    # current assignment from the other side with filter[builds].
    current = {
        g["id"]
        for g in client.get(
            "/v1/betaGroups",
            **{"filter[builds]": build_id, "fields[betaGroups]": "name", "limit": "200"},
        ).get("data", [])
    }
    todo = [g for g in groups if g["id"] not in current]
    if not todo:
        print("✅ Beta groups already attached")
        return
    client.post(
        f"/v1/builds/{build_id}/relationships/betaGroups",
        {"data": [{"type": "betaGroups", "id": g["id"]} for g in todo]},
    )
    print(f"✅ Attached group(s): {', '.join(g['attributes']['name'] for g in todo)}")


def submit_for_review(client: Client, build_id: str) -> str:
    existing = client.get(f"/v1/builds/{build_id}/betaAppReviewSubmission").get("data")
    if existing:
        state = existing["attributes"].get("betaReviewState")
        print(f"✅ Already submitted for Beta App Review (state: {state})")
        return state
    res = client.post(
        "/v1/betaAppReviewSubmissions",
        {
            "data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {
                    "build": {"data": {"type": "builds", "id": build_id}}
                },
            }
        },
    )
    state = res.get("data", {}).get("attributes", {}).get("betaReviewState", "UNKNOWN")
    print(f"✅ Submitted for Beta App Review (state: {state})")
    return state


# --- main ---------------------------------------------------------------


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--config", default="catapult.toml")
    p.add_argument("--version", default="", help="marketing version (git tag)")
    p.add_argument("--build-number", required=True)
    p.add_argument("--notes-file", required=True)
    p.add_argument("--timeout", type=int, default=1200)
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="read App Store Connect but change nothing",
    )
    p.add_argument(
        "--force-notes",
        action="store_true",
        help="overwrite What to Test even if it already has content",
    )
    args = p.parse_args()

    # Keep progress output interleaved correctly with anything on stderr.
    sys.stdout.reconfigure(line_buffering=True)

    with open(args.config, "rb") as f:
        cfg = tomllib.load(f)

    bundle_id = cfg["app"]["bundle_id"]
    tf = cfg.get("testflight", {})
    # Read groups straight from the TOML rather than from the CATAPULT_* env:
    # parse_config.py space-joins lists, which would split "Close Friends".
    group_names = tf.get("groups", [])
    if isinstance(group_names, str):
        group_names = [group_names]
    if not isinstance(group_names, list) or not all(
        isinstance(g, str) for g in group_names
    ):
        raise ASCError("[testflight] groups must be a list of group name strings")
    submit = tf.get("submit_for_review", True)

    with open(args.notes_file) as f:
        notes = f.read()
    if not notes.strip():
        notes = f"Version {args.version}." if args.version else "Maintenance update."

    client = Client(dry_run=args.dry_run)
    if args.dry_run:
        print("🧪 Dry run — no changes will be made.")

    app = find_app(client, bundle_id)
    app_id = app["id"]
    locale = app["attributes"].get("primaryLocale") or "en-US"
    print(f"📱 {app['attributes']['name']} ({bundle_id}) — app id {app_id}")

    build = wait_for_build(
        client, app_id, args.version, args.build_number, args.timeout
    )
    build_id = build["id"]
    print(f"✅ Build {args.build_number} processed")

    set_whats_new(client, build_id, locale, notes, force=args.force_notes)

    if not group_names:
        print("ℹ️  No [testflight] groups configured; nothing to distribute to.")
        return 0

    groups = resolve_groups(client, app_id, group_names)
    external = [g for g in groups if not g["attributes"]["isInternalGroup"]]

    # Apple wants What to Test before review, and the group attached before it
    # can distribute on approval. If attaching is refused because the build
    # isn't approved yet, submit first and then retry.
    try:
        attach_groups(client, build_id, groups)
        attached = True
    except ASCError as e:
        if not external or not submit:
            raise
        print(f"ℹ️  Attaching groups deferred until review is submitted ({e})")
        attached = False

    if external and submit:
        submit_for_review(client, build_id)
        if not attached:
            attach_groups(client, build_id, groups)
    elif external:
        print(
            "ℹ️  submit_for_review = false; external testers stay blocked until "
            "you submit the build for Beta App Review."
        )

    print("")
    print("🎉 TestFlight distribution configured.")
    if external:
        print(
            "   External testers receive it once Apple approves the build "
            "(usually within a day)."
        )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ASCError as e:
        sys.stderr.write(f"❌ {e}\n")
        sys.exit(1)
