#!/usr/bin/env python3
"""Test DSM/Synology Photos authentication without exposing credentials."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import http.cookiejar
import json
import ssl
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_BASE_URL = "https://nas.example.com:5001"


class ProbeError(RuntimeError):
    pass


def load_env(path: Path) -> dict[str, str]:
    """Read a small dotenv file without logging any values."""
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ProbeError(f"Could not read environment file {path}: {exc}") from exc

    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise ProbeError(f"Invalid dotenv entry on line {line_number}")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        values[key] = value

    missing = [key for key in ("USER", "PW", "OTP") if not values.get(key)]
    if missing:
        raise ProbeError(f"Missing required dotenv key(s): {', '.join(missing)}")
    return values


def generate_totp(secret: str, now: int | None = None) -> str:
    """Generate the standard six-digit SHA-1 TOTP used by DSM."""
    candidate = secret.strip()
    if candidate.lower().startswith("otpauth://"):
        parsed = urllib.parse.urlparse(candidate)
        query = urllib.parse.parse_qs(parsed.query)
        candidate = query.get("secret", [""])[0]
    normalized = candidate.replace(" ", "").replace("-", "").upper()
    if not normalized:
        raise ProbeError("OTP secret is empty or invalid")
    normalized += "=" * ((8 - len(normalized) % 8) % 8)
    try:
        key = base64.b32decode(normalized, casefold=True)
    except (ValueError, base64.binascii.Error) as exc:
        raise ProbeError("OTP must be a base32 secret or an otpauth:// URI") from exc

    counter = int(time.time() if now is None else now) // 30
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    number = struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF
    return f"{number % 1_000_000:06d}"


def api_error(payload: dict[str, Any]) -> str:
    error = payload.get("error")
    if not isinstance(error, dict):
        return "unknown API error"
    code = error.get("code", "unknown")
    meanings = {
        400: "invalid credentials or account format",
        401: "account disabled",
        402: "permission denied",
        403: "two-factor authentication required or rejected",
        404: "two-factor authentication failed",
        406: "enforced two-factor authentication setup required",
        407: "IP blocked after too many failed attempts",
        408: "expired password",
        409: "authentication interrupted",
    }
    return f"API error {code}: {meanings.get(code, 'see DSM Login Web API documentation')}"


class SynologyProbe:
    def __init__(self, base_url: str, verify_tls: bool) -> None:
        self.base_url = base_url.rstrip("/")
        cookie_jar = http.cookiejar.CookieJar()
        context = ssl.create_default_context()
        if not verify_tls:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(cookie_jar),
            urllib.request.HTTPSHandler(context=context),
        )
        self.sid: str | None = None
        self.syno_token: str | None = None

    def call(self, path: str, parameters: dict[str, str], *, post: bool = False) -> dict[str, Any]:
        encoded = urllib.parse.urlencode(parameters).encode("utf-8")
        url = f"{self.base_url}{path}"
        if post:
            request = urllib.request.Request(url, data=encoded, method="POST")
        else:
            request = urllib.request.Request(f"{url}?{encoded.decode('ascii')}")
        request.add_header("Accept", "application/json")
        if self.syno_token:
            request.add_header("X-SYNO-TOKEN", self.syno_token)
        try:
            with self.opener.open(request, timeout=20) as response:
                payload = json.load(response)
        except urllib.error.URLError as exc:
            reason = getattr(exc, "reason", exc)
            raise ProbeError(f"Network request failed: {reason}") from exc
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise ProbeError("NAS returned a non-JSON response") from exc
        if not isinstance(payload, dict):
            raise ProbeError("NAS returned an unexpected JSON response")
        return payload

    def discover(self) -> dict[str, Any]:
        payload = self.call(
            "/webapi/entry.cgi",
            {
                "api": "SYNO.API.Info",
                "version": "1",
                "method": "query",
                "query": (
                    "SYNO.API.Auth,SYNO.Foto.Browse.Item,"
                    "SYNO.Foto.Browse.Timeline,SYNO.Foto.Thumbnail,"
                    "SYNO.FotoTeam.Browse.Item"
                ),
            },
        )
        if not payload.get("success"):
            raise ProbeError(f"API discovery failed: {api_error(payload)}")
        data = payload.get("data")
        if not isinstance(data, dict) or "SYNO.API.Auth" not in data:
            raise ProbeError("NAS did not advertise SYNO.API.Auth")
        return data

    def login(self, username: str, password: str, otp_code: str) -> None:
        payload = self.call(
            "/webapi/entry.cgi",
            {
                "api": "SYNO.API.Auth",
                "version": "6",
                "method": "login",
                "account": username,
                "passwd": password,
                "otp_code": otp_code,
                "session": "SynologyPhotos",
                "format": "sid",
                "enable_syno_token": "yes",
                "enable_device_token": "no",
                "device_name": "syno-login-probe",
            },
            post=True,
        )
        if not payload.get("success"):
            raise ProbeError(f"Login failed: {api_error(payload)}")
        data = payload.get("data")
        if not isinstance(data, dict) or not isinstance(data.get("sid"), str):
            raise ProbeError("Login succeeded but returned no session ID")
        self.sid = data["sid"]
        token = data.get("synotoken")
        if isinstance(token, str):
            self.syno_token = token

    def verify_photos_access(self) -> tuple[bool, int | None]:
        if not self.sid:
            raise ProbeError("Cannot query Photos without a session")
        payload = self.call(
            "/webapi/entry.cgi",
            {
                "api": "SYNO.Foto.Browse.Item",
                "version": "1",
                "method": "list",
                "offset": "0",
                "limit": "1",
                "additional": json.dumps(["thumbnail"]),
                "_sid": self.sid,
            },
        )
        if not payload.get("success"):
            raise ProbeError(f"Photos access failed: {api_error(payload)}")
        data = payload.get("data")
        if not isinstance(data, dict):
            return True, None
        total = data.get("total")
        return True, total if isinstance(total, int) else None

    def logout(self) -> None:
        if not self.sid:
            return
        try:
            self.call(
                "/webapi/entry.cgi",
                {
                    "api": "SYNO.API.Auth",
                    "version": "6",
                    "method": "logout",
                    "session": "SynologyPhotos",
                    "_sid": self.sid,
                },
                post=True,
            )
        finally:
            self.sid = None
            self.syno_token = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--env-file", type=Path, default=Path(".env"))
    parser.add_argument(
        "--verify-tls",
        action="store_true",
        help="verify the NAS certificate (currently mismatched for the MagicDNS hostname)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        credentials = load_env(args.env_file)
        otp_code = generate_totp(credentials["OTP"])
        probe = SynologyProbe(args.base_url, verify_tls=args.verify_tls)
        advertised = probe.discover()
        photo_apis = sorted(name for name in advertised if name.startswith("SYNO.Foto"))
        print(f"Connected to DSM; discovered {len(photo_apis)} requested Photos APIs.")
        if not args.verify_tls:
            print("Warning: TLS certificate verification is disabled for this probe.")
        probe.login(credentials["USER"], credentials["PW"], otp_code)
        print("DSM authentication succeeded (credentials and session ID not shown).")
        _, total = probe.verify_photos_access()
        suffix = f"; server reported {total} items" if total is not None else ""
        print(f"Synology Photos Personal Space access succeeded{suffix}.")
        probe.logout()
        print("Session logged out successfully.")
        return 0
    except ProbeError as exc:
        print(f"Login probe failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

