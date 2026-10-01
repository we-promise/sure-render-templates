#!/usr/bin/env python3
"""Read-only identity check for both services before/after persistent app tests.

No deploy hooks, writes, environment-variable reads or credential output.
Render's deploy.image.sha is the image resolved for that deploy; a configured
moving tag or a health response alone is not sufficient evidence.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request


def validate_service(service, deploys, *, kind, owner, environment, digest, url=None):
    if service.get("type") != kind or service.get("ownerId") != owner or service.get("environmentId") != environment:
        raise ValueError("service type/workspace/environment does not match the approved target")
    if url and service.get("serviceDetails", {}).get("url", "").rstrip("/") != url.rstrip("/"):
        raise ValueError("sample URL is not this web service's Render URL")
    live = [row["deploy"] for row in deploys if row.get("deploy", {}).get("status") == "live"]
    if len(live) != 1:
        raise ValueError("expected exactly one live deploy")
    actual = live[0].get("image", {}).get("sha", "")
    actual = actual if actual.startswith("sha256:") else "sha256:" + actual
    if actual != digest:
        raise ValueError("live deploy image SHA does not match the expected release digest")
    return {"service": service["id"], "deploy": live[0]["id"], "image_sha": actual}


def main():
    token = os.environ["RENDER_API_KEY"]
    digest = os.environ["E2E_EXPECTED_IMAGE_DIGEST"]
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("expected an immutable sha256 release digest")

    def get(path):
        req = urllib.request.Request("https://api.render.com/v1" + path, headers={"Authorization": f"Bearer {token}"})
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            # Do not print provider response bodies or request headers.
            raise ValueError(f"Render metadata read failed with HTTP {error.code}") from None

    evidence = []
    for key, kind in (("E2E_WEB_SERVICE_ID", "web_service"), ("E2E_WORKER_SERVICE_ID", "background_worker")):
        sid = os.environ[key]
        if not re.fullmatch(r"srv-[a-z0-9]+", sid):
            raise ValueError("invalid service ID")
        evidence.append(validate_service(
            get(f"/services/{sid}"), get(f"/services/{sid}/deploys?status=live&limit=20"),
            kind=kind, owner=os.environ["E2E_RENDER_OWNER_ID"],
            environment=os.environ["E2E_RENDER_ENVIRONMENT_ID"], digest=digest,
            url=os.environ["E2E_SAMPLE_URL"] if kind == "web_service" else None,
        ))
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, urllib.error.URLError) as error:
        sys.exit(f"Image verification failed: {error}")
