#!/usr/bin/env python3
"""Smoke-test a running Sure: health, sign up, sign out, log in.

  smoke.py <base-url> [--forwarded-proto https]

Used by the local e2e (plain http to the container, with the X-Forwarded-Proto
header Render's proxy would add, because the Blueprint sets RAILS_FORCE_SSL)
and by the Render e2e (real https URL). Cookies are kept in a hand-rolled jar
that ignores the Secure flag, so the same flow works over local http.

Prints one line per step; exits non-zero on the first failure.
"""
import html
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Client:
    def __init__(self, base, proto=None):
        self.base = base.rstrip("/")
        self.proto = proto
        self.cookies = {}
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, method, path, data=None):
        url = self.base + path
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        req = urllib.request.Request(url, data=body, method=method)
        if self.proto:
            req.add_header("X-Forwarded-Proto", self.proto)
        if self.cookies:
            req.add_header("Cookie", "; ".join(f"{k}={v}" for k, v in self.cookies.items()))
        if body is not None:
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
        try:
            resp = self.opener.open(req, timeout=30)
        except urllib.error.HTTPError as e:
            resp = e
        for header in resp.headers.get_all("Set-Cookie") or []:
            name, _, rest = header.partition("=")
            self.cookies[name.strip()] = rest.split(";", 1)[0]
        text = resp.read().decode("utf-8", "replace")
        return resp.status, resp.headers.get("Location", ""), text


def token(page):
    m = re.search(r'name="authenticity_token" value="([^"]+)"', page) or \
        re.search(r'name="csrf-token" content="([^"]+)"', page)
    if not m:
        fail("no CSRF token on the page")
    return html.unescape(m.group(1))


def fail(msg):
    print(f"FAIL {msg}")
    sys.exit(1)


def ok(msg):
    print(f"ok   {msg}")


def is_auth_page(location):
    return any(p in location for p in ("/sessions/new", "/registration/new"))


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    base = args[0]
    proto = args[args.index("--forwarded-proto") + 1] if "--forwarded-proto" in args else None

    anon = Client(base, proto)

    status, loc, _ = anon.request("GET", "/up")
    if status != 200:
        fail(f"GET /up returned {status}")
    ok("GET /up is 200")

    # The Blueprint's healthCheckPath is "/". Render counts 2xx/3xx as healthy.
    status, loc, _ = anon.request("GET", "/")
    if not (200 <= status < 400):
        fail(f"GET / (Render health path) returned {status}")
    ok(f"GET / is {status} (healthy for Render)")
    if status in (301, 308) and loc.startswith("https://") and not base.startswith("https://"):
        fail("GET / redirected to https: X-Forwarded-Proto was not honored")

    email = f"smoke-{int(time.time())}-{secrets.token_hex(3)}@example.com"
    password = "Sm0ke-" + secrets.token_urlsafe(12) + "!9a"

    status, _, page = anon.request("GET", "/registration/new")
    if status != 200:
        fail(f"GET /registration/new returned {status}")
    if 'name="user[invite_code]"' in page:
        fail("sign-up requires an invite code; a fresh self-hosted deploy should allow open sign-up")
    status, loc, _ = anon.request("POST", "/registration", {
        "authenticity_token": token(page),
        "user[email]": email,
        "user[password]": password,
        "user[password_confirmation]": password,
    })
    if status not in (302, 303) or is_auth_page(loc):
        fail(f"sign-up returned {status} -> {loc!r}")
    ok(f"sign-up as {email} -> {status} {urllib.parse.urlparse(loc).path}")

    status, loc, _ = anon.request("GET", "/")
    if is_auth_page(loc):
        fail("signed-up session is not authenticated (redirected to an auth page)")
    ok(f"signed-up session is authenticated (GET / -> {status} {urllib.parse.urlparse(loc).path or ''})")

    fresh = Client(base, proto)
    status, _, page = fresh.request("GET", "/sessions/new")
    if status != 200:
        fail(f"GET /sessions/new returned {status}")
    status, loc, _ = fresh.request("POST", "/sessions", {
        "authenticity_token": token(page),
        "email": email,
        "password": password,
    })
    if status not in (302, 303) or is_auth_page(loc):
        fail(f"log-in returned {status} -> {loc!r}")
    status, loc, _ = fresh.request("GET", "/")
    if is_auth_page(loc):
        fail("logged-in session is not authenticated")
    ok("log-in with the new account works in a fresh session")


if __name__ == "__main__":
    main()
