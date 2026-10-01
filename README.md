# Sure Render Templates

One-click Render Blueprint templates for self-hosting [Sure](https://github.com/we-promise/sure) with six deployment profiles.

## Deployment options

| Option | What it deploys | `latest` | `stable` |
| --- | --- | --- | --- |
| **Sure - No AI** | Sure web, Sidekiq worker, Render Postgres, and Render Key Value. No optional integrations configured. Add supported integrations later in Sure. | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-no-ai-latest) | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-no-ai) |
| **Sure - Simple AI** | Sure with OpenAI-backed AI settings, pgvector-ready Postgres, Sidekiq, and Render Key Value. Configure chat in Sure after deploy; environment overrides are optional. | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-simple-ai-latest) | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-simple-ai) |
| **Sure - External AI** | Sure with external assistant settings plus AlphaClaw, which manages the OpenClaw gateway on Render. Configure optional OpenAI-backed background/PDF features in Sure after deploy. | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-external-ai-latest) | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-external-ai) |

Render expects each button target branch to have a `render.yaml` at the repository root. The branch-ready Blueprint files live in `branches/<branch-name>/render.yaml` and can be copied to each corresponding branch root.

## Optional integrations: configure them after deploy

You do not need OpenAI, SSO, SMTP, PostHog, or Langfuse credentials to create the Sure services. Start with **[the optional integration guide](docs/optional-integrations.md)**: use Sure's settings where supported, and opt into environment variables or an environment group only when needed. The guide covers the current SSO activation flag, SMTP, and embedding limitations in Sure v0.7.5.

For built-in chat, open **Settings → Self-Hosting** and configure the provider there. The Blueprints omit `OPENAI_ACCESS_TOKEN`, `OPENAI_MODEL`, and `OPENAI_URI_BASE`, so Render no longer prompts for the OpenAI token or supplies defaults that lock those UI fields. Simple AI and External AI keep their existing pgvector/embedding defaults; External AI also keeps its intentional AlphaClaw connection wiring.

Already deployed? **[Migrate existing settings](docs/optional-integrations.md#existing-deployments)** before relying on the UI or a group: syncing a Blueprint does not delete old service-level variables. Never put credentials in Git.

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
  sure-no-ai-latest           -> branches/sure-no-ai/render.yaml (image tag rewritten to latest)
  sure-simple-ai-latest       -> branches/sure-simple-ai/render.yaml (image tag rewritten to latest)
  sure-external-ai-latest     -> branches/sure-external-ai/render.yaml (image tag rewritten to latest) + Dockerfile + package.json
```

To materialize the deploy branches from this working branch, run:

```bash
git fetch origin '+refs/heads/sure-*:refs/remotes/origin/sure-*'
./scripts/update-deploy-branches.sh
```

That script creates or updates the six deployment branches locally (stable and latest per flavor), copies the relevant Blueprint to root-level `render.yaml`, rewrites the image tag for the `-latest` branches, commits each branch, and returns you to your original branch. **All six public deployment branches must match the proposed source templates for the drift contract to pass.** Generating them only locally or updating only `main` is not sufficient.

Publishing those branches is a deployment-affecting operation: a Render Blueprint with **Auto Sync** enabled applies changes when its tracked branch is updated. Service-level `autoDeployTrigger: off` does not disable Blueprint sync, and that field has no effect on prebuilt-image services. Before publishing, review every affected Blueprint's sync setting and live configuration, including manually changed plans, image tags, and environment values. A sync can restore template-defined settings, such as downgrading a service that was manually resized. Obtain approval for that impact, or arrange an approved pause of Blueprint Auto Sync first; do not assume that publishing is a no-deploy action.

After those checks, fetch the current deployment refs **before generating**, review each generated diff, and publish all six branches in one atomic push with explicit per-branch leases (the script prints the command). A lease mismatch means a branch changed or was not fetched: stop, fetch, and review again instead of bypassing it. The generator recreates branch histories from the source branch, so a guarded history update can be necessary. Never use an unguarded force push. Rerun the full PR checks against the newly fetched public refs; do not skip or relax the drift check. Blueprint Auto Sync should only be resumed after the desired template and live settings have been reconciled.

## Tests

See [tests/README.md](tests/README.md): unit, contract (including a deploy-branch drift check) and a local docker e2e run on every push and PR for free. A real Render e2e runs manually and is billable (about $0.063/hour for sure-no-ai while it runs).

## Notes

* Services declare `autoDeployTrigger: off` for Git-based service auto-deploys. Blueprint Auto Sync is separate; prebuilt-image services do not use this field. See the publication precautions above.
* The templates use Render-managed Postgres and Render Key Value rather than Docker Compose containers for database and Redis-compatible services.
* The external AI profile shares AlphaClaw's generated `OPENCLAW_GATEWAY_TOKEN` with Sure as `EXTERNAL_ASSISTANT_TOKEN` and routes Sure to AlphaClaw's OpenClaw-compatible gateway at `http://alphaclaw:18789/v1/chat/completions`.
* For external AI, set `MCP_USER_EMAIL` during Blueprint creation to the email of the Sure user that OpenClaw should access through Sure's MCP endpoint. Render also prompts for AlphaClaw's `SETUP_PASSWORD`, `GITHUB_TOKEN`, and `GITHUB_WORKSPACE_REPO` so AlphaClaw can complete its first-run setup without SSH.
