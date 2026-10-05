#!/usr/bin/env python3
"""Publish an Android App Bundle to a Google Play track.

Play takes changes through an "edit": open one, add the bundle, point a track's
release at the new versionCode, then commit. A release on the internal track
reaches testers as soon as the edit commits, with no review.

Auth is a Google Cloud service account that has been invited into Play Console
with permission to release. Its JSON key comes from PLAY_SERVICE_ACCOUNT_JSON,
either the raw JSON or base64 of it, the same way NOTARIZATION_KEY carries the
App Store Connect key. The OAuth assertion is signed with `openssl` so this
stays on the standard library.

Re-running for a versionCode that Play already has skips the upload and only
points the track at it again, so a run that failed halfway can be retried.

Usage:
  upload_play.py --package com.example --bundle app.aab --track internal \\
                 --version-code 1786291989 --release-name "1.2.3 (1786291989)" \\
                 --notes-file notes.txt [--status completed] [--language en-US]
                 [--dry-run]
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

API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD_API = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
# Play's limit on "What's new in this release" per language.
NOTES_MAX = 500


class PlayError(RuntimeError):
    pass


def load_service_account() -> dict:
    raw = os.environ.get("PLAY_SERVICE_ACCOUNT_JSON", "").strip()
    if not raw:
        raise PlayError(
            "PLAY_SERVICE_ACCOUNT_JSON is not set. Put the service account's JSON key "
            "in the app's .env, base64-encoded: base64 -i key.json | tr -d '\\n'"
        )
    try:
        text = raw if raw.startswith("{") else base64.b64decode(raw).decode()
        account = json.loads(text)
    except Exception as e:
        raise PlayError(f"PLAY_SERVICE_ACCOUNT_JSON is neither JSON nor base64 JSON: {e}")
    for field in ("client_email", "private_key"):
        if not account.get(field):
            raise PlayError(f"Service account JSON has no {field}")
    return account


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def sign_rs256(message: bytes, private_key_pem: str) -> bytes:
    fd, key_path = tempfile.mkstemp(prefix="catapult-play-", suffix=".pem")
    try:
        os.chmod(key_path, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(private_key_pem)
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path],
            input=message, capture_output=True, check=False,
        )
        if result.returncode != 0:
            raise PlayError(f"openssl could not sign the token: {result.stderr.decode().strip()}")
        return result.stdout
    finally:
        os.remove(key_path)


def access_token(account: dict) -> str:
    token_uri = account.get("token_uri") or "https://oauth2.googleapis.com/token"
    now = int(time.time())
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = b64url(json.dumps({
        "iss": account["client_email"],
        "scope": SCOPE,
        "aud": token_uri,
        "iat": now,
        "exp": now + 3600,
    }).encode())
    signing_input = f"{header}.{claims}".encode()
    assertion = f"{header}.{claims}.{b64url(sign_rs256(signing_input, account['private_key']))}"
    body = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": assertion,
    }).encode()
    request = urllib.request.Request(token_uri, data=body, method="POST")
    request.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)["access_token"]
    except urllib.error.HTTPError as e:
        raise PlayError(f"Google rejected the service account: {e.read().decode(errors='replace')}")


def call(token: str, method: str, url: str, body=None, data: bytes = None,
         content_type: str = "application/json", timeout: int = 120) -> dict:
    payload = data if data is not None else (json.dumps(body).encode() if body is not None else None)
    request = urllib.request.Request(url, data=payload, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    if payload is not None:
        request.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            text = response.read().decode()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        try:
            detail = json.loads(detail)["error"]["message"]
        except Exception:
            pass
        raise PlayError(f"{method} {url.split('/applications/')[-1]} -> HTTP {e.code}: {detail}")


def release_notes(path: str) -> str:
    """Whole lines from the notes file, as many as fit Play's limit."""
    if not path or not os.path.exists(path):
        return ""
    lines = [line.rstrip() for line in open(path) if line.strip()]
    kept, length = [], 0
    for line in lines:
        extra = len(line) + (1 if kept else 0)
        if length + extra > NOTES_MAX:
            break
        kept.append(line)
        length += extra
    return "\n".join(kept)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", required=True)
    parser.add_argument("--bundle")
    parser.add_argument("--track", default="internal")
    parser.add_argument("--status", default="completed", choices=["completed", "draft"])
    parser.add_argument("--language", default="en-US")
    parser.add_argument("--version-code", type=int)
    parser.add_argument("--release-name")
    parser.add_argument("--notes-file")
    parser.add_argument("--dry-run", action="store_true",
                        help="Check the credentials and app access, then discard the edit")
    args = parser.parse_args()

    account = load_service_account()
    token = access_token(account)
    app = f"{API}/{args.package}"

    edit_id = call(token, "POST", f"{app}/edits", body={})["id"]
    committed = False
    try:
        if args.dry_run:
            tracks = call(token, "GET", f"{app}/edits/{edit_id}/tracks").get("tracks", [])
            names = ", ".join(t["track"] for t in tracks) or "none"
            print(f"✅ {account['client_email']} can edit {args.package} (tracks: {names})")
            return 0

        if not args.bundle or not os.path.exists(args.bundle):
            raise PlayError(f"Bundle not found: {args.bundle}")

        known = {b["versionCode"] for b in call(token, "GET", f"{app}/edits/{edit_id}/bundles").get("bundles", [])}
        if args.version_code and args.version_code in known:
            version_code = args.version_code
            print(f"ℹ️  Play already has versionCode {version_code}; skipping the upload")
        else:
            print(f"⬆️  Uploading {os.path.basename(args.bundle)} ({os.path.getsize(args.bundle) // 1024} KB)")
            with open(args.bundle, "rb") as f:
                uploaded = call(token, "POST",
                                f"{UPLOAD_API}/{args.package}/edits/{edit_id}/bundles?uploadType=media",
                                data=f.read(), content_type="application/octet-stream", timeout=900)
            version_code = uploaded["versionCode"]
            if args.version_code and version_code != args.version_code:
                print(f"⚠️  The bundle's versionCode is {version_code}, not {args.version_code}. "
                      "The app's Gradle config is not reading CATAPULT_BUILD_NUMBER.")

        release = {
            "name": args.release_name or str(version_code),
            "versionCodes": [str(version_code)],
            "status": args.status,
        }
        notes = release_notes(args.notes_file)
        if notes:
            release["releaseNotes"] = [{"language": args.language, "text": notes}]
        call(token, "PUT", f"{app}/edits/{edit_id}/tracks/{args.track}",
             body={"track": args.track, "releases": [release]})
        call(token, "POST", f"{app}/edits/{edit_id}:commit")
        committed = True
        print(f"✅ versionCode {version_code} is on the {args.track} track ({args.status})")
        return 0
    except PlayError as e:
        message = str(e)
        print(f"❌ {message}", file=sys.stderr)
        if "draft app" in message:
            print("   Play only takes draft releases until the app's first release is rolled out "
                  "from Play Console. Set status = \"draft\" under [play] until then.", file=sys.stderr)
        return 1
    finally:
        if not committed:
            try:
                call(token, "DELETE", f"{app}/edits/{edit_id}")
            except PlayError:
                pass


if __name__ == "__main__":
    try:
        sys.exit(main())
    except PlayError as e:
        print(f"❌ {e}", file=sys.stderr)
        sys.exit(1)
