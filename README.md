# Sure Render Templates

One-click Render Blueprint templates for self-hosting [Sure](https://github.com/we-promise/sure) with six deployment profiles.

## Deployment options

| Option | What it deploys | `latest` | `stable` |
| --- | --- | --- | --- |
| **Sure - No AI** | Sure web, Sidekiq worker, Render Postgres, and Render Key Value. AI tokens are intentionally blank. | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-no-ai-latest) | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-no-ai) |
| **Sure - Simple AI** | Sure with OpenAI-backed AI settings, pgvector-ready Postgres, Sidekiq, and Render Key Value. Render prompts for the OpenAI token. | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-simple-ai-latest) | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-simple-ai) |
| **Sure - External AI** | Sure with external assistant settings plus AlphaClaw, which manages the OpenClaw gateway on Render. | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-external-ai-latest) | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-external-ai) |

Render expects each button target branch to have a `render.yaml` at the repository root. The branch-ready Blueprint files live in `branches/<branch-name>/render.yaml` and can be copied to each corresponding branch root.

## Choosing the Sure image tag: `stable` vs `latest`

Each flavor deploys from two branches: the plain branch name (for example `sure-no-ai`) pins `ghcr.io/we-promise/sure:stable` (recommended), and the `-latest` variant (for example `sure-no-ai-latest`) pins `ghcr.io/we-promise/sure:latest` (newest build). Render Blueprint files cannot prompt for values at deploy time, so the tag is a literal per branch.

You can also switch an existing deployment without redeploying the Blueprint: in the Render Dashboard open each service (`sure-web` and `sure-worker`), set the image URL to the tag you want, and trigger a manual deploy. Note that a later Blueprint sync resets the tag to whatever the deployed branch pins. On a fork or clone, `scripts/use-image-tag.sh [stable|latest]` rewrites the tag in every Blueprint file.

## Branch layout

```text
stable >
  sure-no-ai                  -> branches/sure-no-ai/render.yaml
  sure-simple-ai              -> branches/sure-simple-ai/render.yaml
  sure-external-ai            -> branches/sure-external-ai/render.yaml + Dockerfile + package.json
latest >
  sure-no-ai-latest           -> branches/sure-no-ai-latest/render.yaml
  sure-simple-ai-latest       -> branches/sure-simple-ai-latest/render.yaml
  sure-external-ai-latest     -> branches/sure-external-ai-latest/render.yaml + Dockerfile + package.json
```

To materialize the deploy branches from this working branch, run:

```bash
./scripts/update-deploy-branches.sh
```

That script creates or updates the six deployment branches locally (stable and latest per flavor), copies the relevant Blueprint to root-level `render.yaml`, rewrites the image tag for the `-latest` branches, commits each branch, and returns you to your original branch. Push those branches to GitHub so the README buttons can deploy them.

## Notes

* All deployable services use `autoDeployTrigger: off`, the current Render Blueprint setting for disabling automatic deploys on public button branches.
* The templates use Render-managed Postgres and Render Key Value rather than Docker Compose containers for database and Redis-compatible services.
* The external AI profile shares AlphaClaw's generated `OPENCLAW_GATEWAY_TOKEN` with Sure as `EXTERNAL_ASSISTANT_TOKEN` and routes Sure to AlphaClaw's OpenClaw-compatible gateway at `http://alphaclaw:18789/v1/chat/completions`.
* For external AI, set `MCP_USER_EMAIL` during Blueprint creation to the email of the Sure user that OpenClaw should access through Sure's MCP endpoint. Render also prompts for AlphaClaw's `SETUP_PASSWORD`, `GITHUB_TOKEN`, and `GITHUB_WORKSPACE_REPO` so AlphaClaw can complete its first-run setup without SSH.
