#!/usr/bin/env python3
"""Translate a Render Blueprint (render.yaml) into what the tests need.

  blueprint.py compose <render.yaml>                 docker compose YAML on stdout
  blueprint.py render-plan <render.yaml> <suffix>    JSON plan for the Render API on stdout

Both read env vars straight from the Blueprint so the tests can't drift from
what users deploy. Only the Blueprint features this repo uses are supported;
anything else fails loudly instead of being silently dropped.
"""
import json
import os
import secrets
import shlex
import sys

import yaml

SUPPORTED_SERVICE_TYPES = {"web", "worker", "keyvalue"}

# Render can suffix every service name in a Blueprint (sure-web-2clo) when a
# name is already taken in the workspace. Compose services get a suffix too,
# so a hardcoded hostname fails here the way it fails on Render.
COMPOSE_NAME_SUFFIX = "-e2e"

# Values Render prompts for at deploy time (sync: false) come from
# E2E_PROMPT_<KEY>; a missing one fails instead of deploying a blank value.
PROMPT_ENV_PREFIX = "E2E_PROMPT_"

# This adapter creates NEW throwaway services through the API, not Blueprint
# updates. Mirror the Blueprint's omitted-plan creation default explicitly:
# paid 0.5 CPU / 512 MB (the API's backward-compatible "starter" identifier).
# Existing Blueprint-managed services keep their current plan when it is omitted.
# https://render.com/docs/blueprint-spec#plan
NEW_SERVICE_DEFAULT_PLAN = "starter"

# Test-only plan overrides for the e2e harness (Render API / workflow input,
# never part of a Blueprint): E2E_PLAN_WEB / E2E_PLAN_WORKER replace the
# creation default for services of that type, e.g. "standard" (1c-2g) to
# probe whether a failure is memory-related. An explicit plan in the
# Blueprint always wins. Legacy names and new plan IDs are interchangeable:
# https://render.com/docs/compute-plans
OVERRIDE_ENV = {"web": "E2E_PLAN_WEB", "worker": "E2E_PLAN_WORKER"}


def load(path, runtimes=("image",)):
    with open(path) as f:
        bp = yaml.safe_load(f)
    for svc in bp.get("services", []):
        if svc["type"] not in SUPPORTED_SERVICE_TYPES:
            sys.exit(f"unsupported service type {svc['type']!r} in {path}")
        if svc["type"] != "keyvalue" and svc.get("runtime") not in runtimes:
            sys.exit(f"service {svc['name']}: only runtime={'/'.join(runtimes)} is supported (got {svc.get('runtime')!r})")
    return bp


def image_services(bp):
    return [s for s in bp["services"] if s["type"] in ("web", "worker")]


def by_name(bp, name, kind):
    for s in bp.get("services", []):
        if s["name"] == name and s["type"] == kind:
            return s
    sys.exit(f"reference to missing {kind} {name!r}")


def prompted(service, key):
    value = os.environ.get(PROMPT_ENV_PREFIX + key)
    if not value:
        sys.exit(f"{service}.{key}: prompted at deploy time; set {PROMPT_ENV_PREFIX}{key}")
    return value


def resolve_env(bp, svc, db_url, redis_url, generated, host_of=None):
    """Return {key: value} for a service. `generated` is shared across services
    so fromService envVarKey references see the same generated value.
    `host_of(name)` gives a service's private hostname; without it, host
    references are unsupported."""
    out = {}
    for ev in svc.get("envVars", []):
        key = ev["key"]
        if "value" in ev:
            out[key] = str(ev["value"])
        elif ev.get("sync") is False:
            out[key] = prompted(svc["name"], key)
        elif ev.get("generateValue"):
            out[key] = generated.setdefault((svc["name"], key), secrets.token_hex(64))
        elif "fromDatabase" in ev:
            ref = ev["fromDatabase"]
            if ref["name"] not in [d["name"] for d in bp.get("databases", [])]:
                sys.exit(f"{svc['name']}.{key}: missing database {ref['name']!r}")
            if ref["property"] != "connectionString":
                sys.exit(f"{svc['name']}.{key}: unsupported property {ref['property']!r}")
            out[key] = db_url
        elif "fromService" in ev:
            ref = ev["fromService"]
            target = by_name(bp, ref["name"], ref["type"])
            if ref["type"] == "keyvalue" and ref.get("property") == "connectionString":
                out[key] = redis_url
            elif ref["type"] == "web" and ref.get("property") == "host" and host_of:
                out[key] = host_of(target["name"])
            elif "envVarKey" in ref:
                src = [e for e in target.get("envVars", []) if e["key"] == ref["envVarKey"]]
                if not src:
                    sys.exit(f"{svc['name']}.{key}: {target['name']} has no env var {ref['envVarKey']!r}")
                if src[0].get("generateValue"):
                    out[key] = generated.setdefault((target["name"], ref["envVarKey"]), secrets.token_hex(64))
                elif src[0].get("sync") is False:
                    out[key] = prompted(target["name"], ref["envVarKey"])
                else:
                    out[key] = str(src[0]["value"])
            else:
                sys.exit(f"{svc['name']}.{key}: unsupported fromService reference {ref}")
        else:
            sys.exit(f"{svc['name']}.{key}: unsupported env var shape {ev}")
    return out


def compose_escape(value):
    # Compose interpolates $VAR in the file; the container must see it literally.
    return value.replace("$", "$$")


def compose(path):
    bp = load(path, runtimes=("image", "docker"))
    dbs = bp.get("databases", [])
    if len(dbs) != 1:
        sys.exit("expected exactly one database")
    db = dbs[0]
    pw = secrets.token_hex(16)
    db_url = f"postgres://{db['user']}:{pw}@postgres:5432/{db['databaseName']}"
    redis_url = "redis://redis:6379"
    generated = {}
    host_of = lambda name: name + COMPOSE_NAME_SUFFIX  # noqa: E731
    services = {
        "postgres": {
            "image": f"postgres:{db['postgresMajorVersion']}",
            "environment": {"POSTGRES_USER": db["user"], "POSTGRES_PASSWORD": pw, "POSTGRES_DB": db["databaseName"]},
            "healthcheck": {"test": ["CMD-SHELL", f"pg_isready -U {db['user']}"], "interval": "2s", "retries": 60},
        },
        "redis": {
            "image": "redis:7",
            "healthcheck": {"test": ["CMD", "redis-cli", "ping"], "interval": "2s", "retries": 60},
        },
    }
    volumes = {}
    for svc in image_services(bp):
        name = svc["name"]
        env = resolve_env(bp, svc, db_url, redis_url, generated, host_of)
        c = {
            "environment": {k: compose_escape(v) for k, v in env.items()},
            "depends_on": {"postgres": {"condition": "service_healthy"}, "redis": {"condition": "service_healthy"}},
        }
        if svc["runtime"] == "docker":
            # Render builds the deploy branch's Dockerfile; build it from the
            # directory holding this render.yaml (the branch's files).
            c["build"] = {"context": os.path.dirname(os.path.abspath(path))}
        else:
            c["image"] = svc["image"]["url"]
        if "dockerCommand" in svc:
            # Render's dockerCommand replaces CMD; the image ENTRYPOINT still runs.
            c["command"] = [compose_escape(a) for a in shlex.split(svc["dockerCommand"])]
        if os.environ.get("E2E_MEM_LIMIT"):
            # Mirror a Render instance size, e.g. 512m for the default new
            # service. Render doesn't swap, so neither may the container.
            # Applies to every app service, whatever plan the Blueprint sets.
            c["mem_limit"] = c["memswap_limit"] = os.environ["E2E_MEM_LIMIT"]
        if "disk" in svc:
            volumes[svc["disk"]["name"]] = {}
            c["volumes"] = [f"{svc['disk']['name']}:{svc['disk']['mountPath']}"]
        if svc["type"] == "web":
            port = c["environment"].setdefault("PORT", "10000")
            if name == "sure-web":
                c["ports"] = [f"127.0.0.1:${{E2E_WEB_PORT:-3000}}:{port}"]
        services[host_of(name)] = c
    doc = {"services": services}
    if volumes:
        doc["volumes"] = volumes
    yaml.safe_dump(doc, sys.stdout, sort_keys=False)


def render_plan(path, suffix):
    """Resource plan for the Render API. Connection strings for fromDatabase /
    keyvalue references are left as placeholders; tests/render/e2e.sh fills them
    in after the datastores exist."""
    bp = load(path)
    generated = {}
    plan = {"suffix": suffix, "databases": [], "keyvalues": [], "services": []}
    for db in bp.get("databases", []):
        plan["databases"].append({
            "blueprintName": db["name"],
            "name": f"{db['name']}-{suffix}",
            # Blueprint slugs use dashes (basic-1gb); the API uses underscores (basic_1gb).
            "plan": db["plan"].replace("-", "_"),
            "version": str(db["postgresMajorVersion"]),
            "databaseName": db["databaseName"],
            "databaseUser": db["user"],
        })
    for kv in [s for s in bp["services"] if s["type"] == "keyvalue"]:
        resource = {
            "blueprintName": kv["name"],
            "name": f"{kv['name']}-{suffix}",
            "plan": kv["plan"],
            "ipAllowList": kv.get("ipAllowList", []),
        }
        if "maxmemoryPolicy" in kv:
            resource["maxmemoryPolicy"] = kv["maxmemoryPolicy"]
        plan["keyvalues"].append(resource)
    for svc in image_services(bp):
        env = resolve_env(bp, svc, "@@DATABASE_URL@@", "@@REDIS_URL@@", generated)
        if "plan" in svc:
            svc_plan = svc["plan"]
        else:
            svc_plan = os.environ.get(OVERRIDE_ENV.get(svc["type"], ""), "") or NEW_SERVICE_DEFAULT_PLAN
        details = {"runtime": "image", "plan": svc_plan}
        if svc.get("healthCheckPath"):
            details["healthCheckPath"] = svc["healthCheckPath"]
        if svc.get("disk"):
            details["disk"] = {"name": svc["disk"]["name"], "mountPath": svc["disk"]["mountPath"],
                               "sizeGB": svc["disk"]["sizeGB"]}
        if svc.get("dockerCommand"):
            details["envSpecificDetails"] = {"dockerCommand": svc["dockerCommand"]}
        plan["services"].append({
            "blueprintName": svc["name"],
            "type": "web_service" if svc["type"] == "web" else "background_worker",
            "name": f"{svc['name']}-{suffix}",
            "imagePath": svc["image"]["url"],
            "autoDeploy": "no",
            "envVars": [{"key": k, "value": v} for k, v in env.items()],
            "serviceDetails": details,
        })
    json.dump(plan, sys.stdout, indent=2)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "compose":
        compose(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "render-plan":
        render_plan(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
