# Tests

This repo is Render Blueprints plus two scripts. There's no app code, so the tests check what this repo ships: the six deploy-branch Blueprints, the scripts that generate them, and whether a Blueprint actually boots a working Sure. Layers are split by cost, following [garrytan/openclaw-render-template/tests](https://github.com/garrytan/openclaw-render-template/tree/main/tests).

| Layer | What it checks | Needs | Cost | Runs |
| --- | --- | --- | --- | --- |
| **unit** | `scripts/use-image-tag.sh` rewrites only image url lines. `scripts/update-deploy-branches.sh` builds all 6 branches with the right root `render.yaml` and keeps the AlphaClaw build files only on external-ai branches. Both run in a throwaway clone. | bats, git | $0 | PRs, push to main |
| **contract** | Static invariants over every Blueprint: image tag matches the branch name, `autoDeployTrigger: off`, Postgres basic-1gb on PG 18, starter sizing + Puma 1x3, health check + storage disk, worker runs Sidekiq with web's `SECRET_KEY_BASE`, no dangling env references, no-AI settings blank, SSL settings on. **Drift check**: each live deploy branch equals what the generator would produce from `branches/`. Workflow guard rails and shellcheck. | bats, python3 + PyYAML, shellcheck | $0 | PRs, push to main |
| **local e2e** | Boots a deploy branch's Blueprint in docker compose, generated from that branch's own `render.yaml` (`tests/lib/blueprint.py`). Checks: right image; web + worker stay up; DB fully migrated; runs as behind a TLS proxy (https links + HSTS on plain http, since `RAILS_ASSUME_SSL`/`RAILS_FORCE_SSL` are on); smoke through the `X-Forwarded-Proto: https` header Render's proxy adds: open sign-up, log in from a fresh session, onboarding, a manual cash account, an expense added through the transaction form and shown in the list, and the worker's account sync moving the balance; Sidekiq registered in Redis; a job enqueued by web gets processed; `rake demo_data:default` (the README way) loads and the demo user sees the demo accounts and transactions. Render e2e runs the same checks. | docker, bats, curl, python3 + PyYAML | $0 | PRs, push to main, every new Sure stable/alpha/nightly |
| **Render e2e** | Creates the Blueprint's resources in Render through the API, at the Blueprint's own plans, named `<name>-e2e-<run>`. Waits for the deploys to go live, runs the same smoke (sign-up through the worker-synced balance) against the real https URL, checks migrations and the Sidekiq worker and loads demo data through Render one-off jobs, then deletes everything and verifies nothing with the run's suffix is left. Also runs Render's Blueprint validate API on all 6 files. | `RENDER_API_KEY` secret | **billable**, see below | every new Sure stable and alpha release, or manual (`render e2e` workflow) |

```sh
tests/run.sh           # unit + contract (fast, no docker)
tests/run.sh e2e       # local e2e (E2E_BRANCH=sure-no-ai by default)
tests/run.sh all
```

## Release-triggered runs

This repo changes rarely; Sure changes often. So the suite also runs on every new Sure build, with no one in the loop:

- `release watch` runs every 6 hours and starts `release test` once per new build (`tests/release/watch.sh`). A build counts as tested once any run exists for it, so a failed run stays red rather than being retried.
- New stable [release](https://github.com/we-promise/sure/releases) (any non-prerelease, hotfixes included) → `release test stable vX.Y.Z` → local e2e + Render e2e on the stable deploy branches.
- New alpha (`*-alpha*` prerelease) → `release test latest vX.Y.Z-alpha.N` → local e2e + Render e2e on the `-latest` deploy branches. Plenty of people run production on alphas.
- New `ghcr.io/we-promise/sure:nightly` digest → `release test nightly sha256:...` → local e2e only, running `sure-no-ai`'s Blueprint with that exact digest. Nightlies aren't GitHub Releases, so they're tracked by digest.
- Why Releases for stable/alpha: Sure's `publish.yml` tags `v*-alpha*` images as `:latest` and every other `v*` as `:stable`, and creates the GitHub Release only after the image is pushed. The run checks that `:stable`/`:latest` still points at the release's version tag and warns if it has moved on.
- Render e2e cost: about $0.03-0.07 per run. At Sure's recent pace (about 1 stable a month, an alpha every few days) that's roughly $0.50-1/month. Kill switch: set the repo variable `RENDER_E2E_ON_RELEASE` to `false` (Settings → Secrets and variables → Actions → Variables). If the `RENDER_API_KEY` secret is missing, the Render jobs skip with a notice instead of failing.
- Failures show up as a red `release test` run and GitHub's normal notifications.

Render e2e from a laptop (billable):

```sh
export RENDER_API_KEY=...            # never commit it
E2E_CONFIRM_COST=yes tests/render/e2e.sh
tests/render/validate.sh             # free; creates nothing
DRY_RUN=1 tests/render/sweep.sh      # list leaked e2e resources
```

## Render e2e cost

From [render.com/pricing](https://render.com/pricing), billed per second while resources exist:

| Resource (sure-no-ai) | Plan | Monthly |
| --- | --- | --- |
| sure-web | starter | $7 |
| sure-worker | starter | $7 |
| sure-redis | Key Value starter | $10 |
| sure-postgres | basic-1gb | $19 |
| sure-storage disk | 10 GB × $0.25 | $2.50 |
| **total** | | **$45.50/mo ≈ $0.063/hour** |

A run takes about 30-60 minutes including provisioning, so it costs about $0.03-0.07. Three layers stop resources from leaking:

1. `e2e.sh` tears down on exit.
2. The workflow's `Teardown` step runs `if: always()`, which covers cancel and timeout.
3. `render sweep` deletes any `*-e2e-*` resource older than 2 hours, every hour.

`teardown.sh` also lists resources by name afterwards and fails the run if anything with the run's suffix is still there.

The API creates the Blueprint's resources one by one. Render has no public API to instantiate a Blueprint. Plans, env vars, disk, health check and worker command all come from the branch's `render.yaml`.

## Adding a combination

1. Add the deploy branch to the `e2e-local` matrix in `.github/workflows/test.yml`, to the channel's branch list in `release-test.yml`, and to the `branch` choices in `render-e2e.yml`. Render resource names are suffixed with the run id only, so before a channel gets more than one branch, add the branch to the suffix in `tests/render/e2e.sh` and the workflow's teardown step.
2. Extend `tests/lib/blueprint.py` for any Blueprint feature it doesn't support yet. It fails loudly on unsupported features: `sync: false` prompted secrets (simple-ai), and docker-runtime services (external-ai's AlphaClaw).
3. Add flavor-specific assertions (pgvector for simple-ai, the gateway wiring for external-ai).

## Assertion rules

Same rules as Garry's suites:

- Negatives are `run <cmd>` + `[ "$status" -ne 0 ]`, never a bare `! cmd` (bats doesn't fail on it).
- Missing prerequisites fail, they don't skip. A skip shows green, and CI must never go green unproven. One deliberate exception: the Render e2e skips (with a notice) when `RENDER_API_KEY` isn't set, so release runs stay green until the key is added.
