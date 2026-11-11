#!/usr/bin/env python3
"""A software passkey for the Pocket ID test user, so tests can act as the
user's "other signed-in device" without a browser.

  passkey.py enroll                  register a passkey (once, via the API key)
  passkey.py approve <code>          sign in with the passkey, approve the code
  passkey.py deny <code>             sign in with the passkey, deny the code
  passkey.py forget <client>         withdraw consent (next login asks again)

The private key is kept in data/passkey.json (git-ignored). Standard library
only: P-256 ECDSA and the bit of CBOR WebAuthn needs are implemented here.
Test use only: the signing is not constant-time.
"""
import base64
import hashlib
import json
import os
import secrets
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
KEY_FILE = os.path.join(HERE, "data", "passkey.json")

# NIST P-256.
P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
A = P - 3
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
G = (
    0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
    0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5,
)


def _add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    (x1, y1), (x2, y2) = p1, p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        m = (3 * x1 * x1 + A) * pow(2 * y1, -1, P)
    else:
        m = (y2 - y1) * pow(x2 - x1, -1, P)
    x3 = (m * m - x1 - x2) % P
    return x3, (m * (x1 - x3) - y1) % P


def _mul(k, point=G):
    result = None
    while k:
        if k & 1:
            result = _add(result, point)
        point = _add(point, point)
        k >>= 1
    return result


def _der_int(v):
    b = v.to_bytes(32, "big").lstrip(b"\0") or b"\0"
    if b[0] & 0x80:
        b = b"\0" + b
    return b"\x02" + bytes([len(b)]) + b


def sign(d, data):
    z = int.from_bytes(hashlib.sha256(data).digest(), "big")
    while True:
        k = secrets.randbelow(N - 1) + 1
        r = _mul(k)[0] % N
        s = pow(k, -1, N) * (z + r * d) % N
        if r and s:
            body = _der_int(r) + _der_int(s)
            return b"\x30" + bytes([len(body)]) + body


def _cbor_head(major, n):
    if n < 24:
        return bytes([major << 5 | n])
    for size, extra in ((1, 24), (2, 25), (4, 26), (8, 27)):
        if n < 1 << (8 * size):
            return bytes([major << 5 | extra]) + n.to_bytes(size, "big")
    raise ValueError(n)


def cbor(v):
    if isinstance(v, bool) or v is None:
        raise ValueError(v)
    if isinstance(v, int):
        return _cbor_head(0, v) if v >= 0 else _cbor_head(1, -1 - v)
    if isinstance(v, bytes):
        return _cbor_head(2, len(v)) + v
    if isinstance(v, str):
        b = v.encode()
        return _cbor_head(3, len(b)) + b
    if isinstance(v, dict):
        out = _cbor_head(5, len(v))
        for key, value in v.items():
            out += cbor(key) + cbor(value)
        return out
    raise ValueError(v)


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64u(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                env[key.removeprefix("export ").strip()] = value.strip("'\"")
    return env


class Browser:
    """Plain HTTP with a cookie jar that ignores the Secure flag (the test
    server runs on http://)."""

    def __init__(self, base, origin):
        self.base = base
        self.origin = origin
        self.cookies = {}

    def call(self, method, path, body=None, headers=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if self.cookies:
            req.add_header(
                "Cookie", "; ".join(f"{k}={v}" for k, v in self.cookies.items())
            )
        for key, value in (headers or {}).items():
            req.add_header(key, value)
        try:
            resp = urllib.request.urlopen(req, timeout=40)
        except urllib.error.HTTPError as e:
            resp = e
        for header in resp.headers.get_all("Set-Cookie") or []:
            name, _, rest = header.partition("=")
            value = rest.split(";", 1)[0]
            if value and "Max-Age=0" not in header:
                self.cookies[name.strip()] = value
            else:
                self.cookies.pop(name.strip(), None)
        text = resp.read().decode()
        status = resp.status if hasattr(resp, "status") else resp.code
        if status >= 400:
            raise SystemExit(f"{method} {path}: {status} {text[:200]}")
        return json.loads(text) if text.strip() else None


def client_data(kind, challenge, origin):
    return json.dumps(
        {"type": kind, "challenge": challenge, "origin": origin, "crossOrigin": False},
        separators=(",", ":"),
    ).encode()


def enroll(env, browser):
    api = {"X-API-Key": env["POCKET_ID_API_KEY"]}
    users = browser.call(
        "GET", "/api/users?search=" + env["ABS_TEST_USER"], headers=api
    )["data"]
    user = next(u for u in users if u["username"] == env["ABS_TEST_USER"])
    token = browser.call(
        "POST", f"/api/users/{user['id']}/one-time-access-token",
        {"ttl": "5m"}, headers=api,
    )["token"]
    browser.call("POST", f"/api/one-time-access-token/{token}")
    options = browser.call("GET", "/api/webauthn/register/start")
    options = options.get("publicKey", options)
    d = secrets.randbelow(N - 1) + 1
    x, y = _mul(d)
    cred_id = secrets.token_bytes(32)
    cose = cbor({1: 2, 3: -7, -1: 1, -2: x.to_bytes(32, "big"), -3: y.to_bytes(32, "big")})
    rp_id = options["rp"]["id"]
    auth_data = (
        hashlib.sha256(rp_id.encode()).digest()
        + bytes([0x45])  # user present, user verified, attested data
        + (0).to_bytes(4, "big")
        + bytes(16)  # AAGUID
        + len(cred_id).to_bytes(2, "big")
        + cred_id
        + cose
    )
    attestation = cbor({"fmt": "none", "attStmt": {}, "authData": auth_data})
    cdj = client_data("webauthn.create", options["challenge"], browser.origin)
    browser.call("POST", "/api/webauthn/register/finish", {
        "id": b64u(cred_id), "rawId": b64u(cred_id), "type": "public-key",
        "response": {
            "clientDataJSON": b64u(cdj), "attestationObject": b64u(attestation),
            "transports": ["internal"],
        },
        "clientExtensionResults": {},
    })
    os.makedirs(os.path.dirname(KEY_FILE), exist_ok=True)
    fd = os.open(KEY_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({
            "credentialId": b64u(cred_id), "d": hex(d),
            "userHandle": options["user"]["id"], "rpId": rp_id, "signCount": 0,
        }, f)
    print("passkey enrolled for", env["ABS_TEST_USER"])


def login(browser):
    with open(KEY_FILE) as f:
        key = json.load(f)
    options = browser.call("GET", "/api/webauthn/login/start")
    options = options.get("publicKey", options)
    key["signCount"] += 1
    auth_data = (
        hashlib.sha256(key["rpId"].encode()).digest()
        + bytes([0x05])  # user present, user verified
        + key["signCount"].to_bytes(4, "big")
    )
    cdj = client_data("webauthn.get", options["challenge"], browser.origin)
    signature = sign(int(key["d"], 16), auth_data + hashlib.sha256(cdj).digest())
    browser.call("POST", "/api/webauthn/login/finish", {
        "id": key["credentialId"], "rawId": key["credentialId"],
        "type": "public-key",
        "response": {
            "clientDataJSON": b64u(cdj), "authenticatorData": b64u(auth_data),
            "signature": b64u(signature), "userHandle": key["userHandle"],
        },
        "clientExtensionResults": {},
    })
    fd = os.open(KEY_FILE, os.O_WRONLY | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(key, f)


def decide(browser, code, decision):
    login(browser)
    if decision == "approve":
        # A passkey login less than a minute old counts as reauthentication.
        browser.call("POST", "/api/webauthn/reauthenticate")
    info = browser.call("POST", "/api/device-login/verification", {"code": code})
    browser.call(
        "POST", "/api/device-login/verification/decision",
        {"code": code, "decision": decision},
    )
    print(decision, info["userCode"], "from", info["device"])


def forget(browser, client):
    """Withdraws the user's consent for an OIDC client, so the next login
    asks again."""
    login(browser)
    browser.call("DELETE", f"/api/oidc/users/me/authorized-clients/{client}")
    print("consent withdrawn for", client)


def main():
    env = load_env(os.path.join(HERE, ".env"))
    url = env["POCKET_ID_URL"].rstrip("/")
    base = os.environ.get("POCKET_ID_LOCAL_URL", url)
    browser = Browser(base.rstrip("/"), url)
    match sys.argv[1:]:
        case ["enroll"]:
            enroll(env, browser)
        case ["approve" | "deny" as decision, code]:
            decide(browser, code, decision)
        case ["forget", client]:
            forget(browser, client)
        case _:
            raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
