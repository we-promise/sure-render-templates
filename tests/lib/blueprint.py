#!/usr/bin/env python3
"""Translate a Render Blueprint (render.yaml) into what the tests need.

  blueprint.py compose <render.yaml>                 docker compose YAML on stdout
  blueprint.py render-plan <render.yaml> <suffix>    JSON plan for the Render API on stdout

Both read env vars straight from the Blueprint so the tests can't drift from
what users deploy. Only the Blueprint features this repo uses are supported;
anything else fails loudly instead of being silently dropped.
"""
import json
import secrets
import sys

import yaml

SUPPORTED_SERVICE_TYPES = {"web", "worker", "keyvalue"}


def load(path):
    with open(path) as f:
        bp = yaml.safe_load(f)
    for svc in bp.get("services", []):
        if svc["type"] not in SUPPORTED_SERVICE_TYPES:
            sys.exit(f"unsupported service type {svc['type']!r} in {path}")
        if svc["type"] != "keyvalue" and svc.get("runtime") != "image":
            sys.exit(f"service {svc['name']}: only runtime=image is supported (got {svc.get('runtime')!r})")
    return bp


def image_services(bp):
    return [s for s in bp["services"] if s["type"] in ("web", "worker")]


def by_name(bp, name, kind):
    for s in bp.get("services", []):
        if s["name"] == name and s["type"] == kind:
            return s
    sys.exit(f"reference to missing {kind} {name!r}")


def resolve_env(bp, svc, db_url, redis_url, generated):
    """Return {key: value} for a service. `generated` is shared across services
    so fromService envVarKey references see the same generated value."""
    out = {}
    for ev in svc.get("envVars", []):
        key = ev["key"]
        if "value" in ev:
            out[key] = str(ev["value"])
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
            elif "envVarKey" in ref:
                src = [e for e in target.get("envVars", []) if e["key"] == ref["envVarKey"]]
                if not src:
                    sys.exit(f"{svc['name']}.{key}: {target['name']} has no env var {ref['envVarKey']!r}")
                if src[0].get("generateValue"):
                    out[key] = generated.setdefault((target["name"], ref["envVarKey"]), secrets.token_hex(64))
                else:
                    out[key] = str(src[0]["value"])
            else:
                sys.exit(f"{svc['name']}.{key}: unsupported fromService reference {ref}")
        else:
            sys.exit(f"{svc['name']}.{key}: unsupported env var shape {ev}")
    return out


def compose(path):
    bp = load(path)
    dbs = bp.get("databases", [])
    if len(dbs) != 1:
        sys.exit("expected exactly one database")
    db = dbs[0]
    pw = secrets.token_hex(16)
    db_url = f"postgres://{db['user']}:{pw}@postgres:5432/{db['databaseName']}"
    redis_url = "redis://redis:6379"
    generated = {}
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
        c = {
            "image": svc["image"]["url"],
            "environment": resolve_env(bp, svc, db_url, redis_url, generated),
            "depends_on": {"postgres": {"condition": "service_healthy"}, "redis": {"condition": "service_healthy"}},
        }
        if "dockerCommand" in svc:
            # Render's dockerCommand replaces CMD; the image ENTRYPOINT still runs.
            c["command"] = svc["dockerCommand"].split()
        if "disk" in svc:
            volumes[svc["disk"]["name"]] = {}
            c["volumes"] = [f"{svc['disk']['name']}:{svc['disk']['mountPath']}"]
        if svc["type"] == "web":
            port = c["environment"].setdefault("PORT", "10000")
            c["ports"] = [f"127.0.0.1:${{E2E_WEB_PORT:-3000}}:{port}"]
        services[name] = c
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
        plan["keyvalues"].append({
            "blueprintName": kv["name"],
            "name": f"{kv['name']}-{suffix}",
            "plan": kv["plan"],
            "ipAllowList": kv.get("ipAllowList", []),
        })
    for svc in image_services(bp):
        env = resolve_env(bp, svc, "@@DATABASE_URL@@", "@@REDIS_URL@@", generated)
        details = {"runtime": "image", "plan": svc["plan"]}
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
