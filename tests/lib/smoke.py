#!/usr/bin/env python3
"""Smoke-test a running Sure the way a new self-hoster would use it.

  smoke.py <base-url> [--forwarded-proto https] [--demo]

Default flow: health, open sign-up, log in from a fresh session, complete
onboarding, create a manual cash account, add an expense through the normal
transaction form, see it in the transactions list, and wait for the worker's
account sync to move the balance.

--demo instead logs in as the README's demo user (user@example.com /
Password1!, created by `rake demo_data:default`) and checks the demo accounts
and transactions are visible.

Used by the local e2e (plain http to the container, with the X-Forwarded-Proto
header Render's proxy would add, because the Blueprint sets RAILS_FORCE_SSL)
and by the Render e2e (real https URL). Cookies are kept in a hand-rolled jar
that ignores the Secure flag, so the same flow works over local http.

Prints one line per step; exits non-zero on the first failure.
"""
import datetime
import html
import html.parser
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


class Forms(html.parser.HTMLParser):
    """Collect every <form> with the values a browser would submit by default."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.forms, self.cur, self.select, self.radios = [], None, None, {}

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form":
            self.cur = {"action": a.get("action", ""), "method": (a.get("method") or "get").lower(), "fields": []}
            self.forms.append(self.cur)
            self.radios = {}
        if self.cur is None:
            return
        name = a.get("name")
        if tag == "input" and name:
            kind = (a.get("type") or "text").lower()
            if kind in ("submit", "button", "image", "file"):
                return
            if kind == "checkbox":
                if "checked" in a:
                    self.cur["fields"].append((name, a.get("value", "on")))
                return
            if kind == "radio":
                if "checked" in a or name not in self.radios:
                    if name in self.radios:
                        self.cur["fields"].remove(self.radios[name])
                    self.radios[name] = (name, a.get("value", "on"))
                    self.cur["fields"].append(self.radios[name])
                return
            self.cur["fields"].append((name, a.get("value", "")))
        elif tag == "select" and name:
            self.select = {"name": name, "first": None, "chosen": None}
        elif tag == "option" and self.select is not None:
            v = a.get("value", "")
            if self.select["first"] is None and v:
                self.select["first"] = v
            if "selected" in a:
                self.select["chosen"] = v
        elif tag == "textarea" and name:
            self.cur["fields"].append((name, ""))

    def handle_endtag(self, tag):
        if tag == "select" and self.select is not None and self.cur is not None:
            v = self.select["chosen"] or self.select["first"] or ""
            self.cur["fields"].append((self.select["name"], v))
            self.select = None
        elif tag == "form":
            self.cur = None


def form(page, action_re):
    """The first form whose action matches, as (action, dict of default values)."""
    parser = Forms()
    parser.feed(page)
    for f in parser.forms:
        if re.search(action_re, f["action"]) and f["method"] == "post":
            return html.unescape(f["action"]), dict(f["fields"])
    fail(f"no form posting to {action_re!r} on the page")


def submit(client, page_path, action_re, overrides, what):
    status, loc, page = client.request("GET", page_path)
    if status != 200:
        fail(f"{what}: GET {page_path} returned {status} -> {loc!r}")
    action, fields = form(page, action_re)
    fields.update(overrides)
    status, loc, body = client.request("POST", urllib.parse.urlparse(action).path or action, fields)
    if status not in (302, 303):
        errs = re.findall(r'(?:error|alert)[^>]*>\s*([^<]{3,200})', body)
        fail(f"{what}: POST {action} returned {status} {errs[:3]}")
    return urllib.parse.urlparse(loc).path


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

    if "--demo" in args:
        demo_flow(base, proto)
        return

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

    new_user_flow(fresh)


def new_user_flow(c):
    # Onboarding: the same three wizard forms a browser submits.
    status, loc, _ = c.request("GET", "/")
    if "/onboarding" not in loc:
        fail(f"a new user should be sent to onboarding, got GET / -> {status} {loc!r}")
    nxt = submit(c, "/onboarding", r"^/users/", {
        "user[first_name]": "Smoke", "user[last_name]": "Test",
        "user[family_attributes][name]": "Smoke Household",
    }, "onboarding (profile)")
    if nxt != "/onboarding/preferences":
        fail(f"onboarding profile step went to {nxt!r}, expected /onboarding/preferences")
    nxt = submit(c, "/onboarding/preferences", r"^/users/", {
        "user[family_attributes][currency]": "USD",
    }, "onboarding (preferences)")
    if nxt != "/onboarding/goals":
        fail(f"onboarding preferences step went to {nxt!r}, expected /onboarding/goals")
    nxt = submit(c, "/onboarding/goals", r"^/users/", {}, "onboarding (goals)")
    status, loc, _ = c.request("GET", "/")
    if status != 200:
        fail(f"after onboarding GET / returned {status} -> {loc!r} (expected the dashboard)")
    ok(f"onboarding completed (goals -> {nxt}), dashboard is 200")

    # A manual cash account with an opening balance.
    acct = f"Smoke Cash {secrets.token_hex(2)}"
    path = submit(c, "/depositories/new", r"^/depositories$", {
        "account[name]": acct, "account[balance]": "1000", "account[currency]": "USD",
    }, "create account")
    m = re.match(r"^/accounts/([0-9a-f-]{36})", path)
    if not m:
        fail(f"account create redirected to {path!r}, expected /accounts/<id>")
    account_id = m.group(1)
    ok(f"created manual account {acct!r} with a 1,000.00 opening balance")

    # An expense through the normal "new transaction" form.
    txn = f"Smoke coffee {secrets.token_hex(3)}"
    submit(c, f"/transactions/new?account_id={account_id}", r"^/transactions$", {
        "entry[account_id]": account_id, "entry[name]": txn, "entry[amount]": "42.17",
        "entry[currency]": "USD", "entry[nature]": "outflow",
        "entry[date]": datetime.date.today().isoformat(),
    }, "add transaction")
    status, _, page = c.request("GET", "/transactions")
    if status != 200 or html.escape(txn) not in page:
        fail(f"new transaction {txn!r} is not in the transactions list (status {status})")
    ok(f"added expense {txn!r} (42.17) and it shows in the transactions list")

    # The worker's account sync recalculates the balance: 1,000.00 - 42.17.
    deadline = time.time() + 180
    while True:
        status, _, page = c.request("GET", "/accounts")
        if "957.83" in page:
            break
        if time.time() > deadline:
            shown = re.findall(r"[$€£]\s?[\d,]+\.\d\d", page)[:6]
            fail(f"account balance never became 957.83 (worker sync); /accounts shows {shown}")
        time.sleep(3)
    ok("worker synced the account: balance is now 957.83")


def demo_flow(base, proto):
    c = Client(base, proto)
    status, _, page = c.request("GET", "/sessions/new")
    if status != 200:
        fail(f"GET /sessions/new returned {status}")
    status, loc, _ = c.request("POST", "/sessions", {
        "authenticity_token": token(page), "email": "user@example.com", "password": "Password1!",
    })
    if status not in (302, 303) or is_auth_page(loc):
        fail(f"demo user log-in returned {status} -> {loc!r}")
    status, loc, _ = c.request("GET", "/")
    if status != 200:
        fail(f"demo user dashboard returned {status} -> {loc!r}")
    ok("logged in as the demo user (user@example.com), dashboard is 200")
    status, _, page = c.request("GET", "/accounts")
    want = ["Chase Premier Checking", "Marcus High-Yield Savings", "Amex Gold Card", "Vanguard 401(k)"]
    missing = [a for a in want if html.escape(a) not in page]
    if status != 200 or missing:
        fail(f"demo accounts missing from /accounts: {missing} (status {status})")
    ok(f"demo accounts are listed ({', '.join(want)})")
    status, _, page = c.request("GET", "/transactions")
    rows = page.count('id="entry_')
    if status != 200 or rows < 10:
        fail(f"demo transactions page shows {rows} entries (status {status}), expected a full page")
    ok(f"demo transactions are listed ({rows} on the first page)")


if __name__ == "__main__":
    main()
