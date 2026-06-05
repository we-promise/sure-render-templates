# Sure Render Templates

One-click Render Blueprint templates for self-hosting [Sure](https://github.com/we-promise/sure) with three deployment profiles.

## Deployment options

| Option | What it deploys | Deploy |
| --- | --- | --- |
| **Sure — No AI** | Sure web, Sidekiq worker, Render Postgres, and Render Key Value. AI tokens are intentionally blank. | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-no-ai) |
| **Sure — Simple AI** | Sure with OpenAI-backed AI settings, pgvector-ready Postgres, Sidekiq, and Render Key Value. Render prompts for the OpenAI token. | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-simple-ai) |
| **Sure — External AI** | Sure with external assistant settings plus AlphaClaw, which manages the OpenClaw gateway on Render. | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-external-ai) |

Render expects each button target branch to have a `render.yaml` at the repository root. The branch-ready Blueprint files live in `branches/<branch-name>/render.yaml` and can be copied to each corresponding branch root.

## Branch layout

```text
sure-no-ai          -> branches/sure-no-ai/render.yaml
sure-simple-ai      -> branches/sure-simple-ai/render.yaml
sure-external-ai    -> branches/sure-external-ai/render.yaml + Dockerfile + package.json
```

To materialize the deploy branches from this working branch, run:

```bash
./scripts/update-deploy-branches.sh
```

That script creates or updates the three deployment branches locally, copies the relevant Blueprint to root-level `render.yaml`, commits each branch, and returns you to your original branch. Push those branches to GitHub so the README buttons can deploy them.

## Notes

* All services use `autoDeploy: false`, as recommended for repositories deployed by public Render buttons.
* The templates use Render-managed Postgres and Render Key Value rather than Docker Compose containers for database and Redis-compatible services.
* The external AI profile shares AlphaClaw's generated `OPENCLAW_GATEWAY_TOKEN` with Sure as `EXTERNAL_ASSISTANT_TOKEN`.
* For external AI, set `MCP_USER_EMAIL` during Blueprint creation to the email of the Sure user that OpenClaw should access through Sure's MCP endpoint.
