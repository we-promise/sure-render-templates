# Proposed stable deployment to the persistent Sure app

Status: review proposal, **not enabled**. No deployment hook, secret, scheduled
run or Sure release-workflow change is included in this test-harness change.

## Targets and lifecycle

- Render workspace: Sure (`tea-d274nlc9c44c73833lu0`).
- Project: Sure app (`prj-daurn73ncjis7382kaj0`).
- Initial environment: Production (`evm-daurn73ncjis7382kak0`).
- Persistent public sample application; it is separate from `sure-demo` (alphas)
  and `app.sure.am` on AWS/EKS. Do not modify DNS or wipe sample data.
- User provisions the stable `sure-simple-ai` Blueprint and securely configures
  credentials. The project/environment alone currently have no services.

## Proposed Sure publish-workflow change

After product approval, add a separate stable job after image manifest publication
in `we-promise/sure/.github/workflows/publish.yml`. Preserve the existing alpha
job. Require an actual tag-push event and the exact final-tag pattern
`^v[0-9]+\.[0-9]+\.[0-9]+$`; RC, beta, alpha, nightly, branch pushes and arbitrary
manual refs must not qualify. A job-level coarse filter is not enough: apply the
anchored pattern before accessing hooks. Add negative checks for `v0.7.6-rc.1`,
`v0.7.6-beta.1`, `v0.7.6-alpha.1`, malformed tags and manual events.

Export the immutable merged manifest digest from the merge job. Use that exact
`ghcr.io/we-promise/sure@sha256:…` image for both web and worker; never deploy a
moving `stable` alias as the identity of a particular release. Record any
platform-specific resolution explicitly rather than accepting a mismatch.

Use a dedicated GitHub environment (proposed name: `sure-app`) and a stable-only
concurrency group with `cancel-in-progress: false`. Its service/workspace/Render
environment IDs and HTTPS URL are nonsecret variables. Keep hook URLs as secrets,
entered securely after the services exist. A read-only Render metadata check
must verify both service IDs, types, workspace and environment before invoking
hooks. Do not infer the worker target from a web hook or let a shared variable
silently retarget the alpha rollout.

For each deployment, inspect the returned deploy identity and wait for that
specific deploy to become live with the expected image SHA, using a bounded
wait. A successful hook HTTP response is only an acknowledgement. A web `/up`
response or a registered Sidekiq process cannot prove both new images are live.
Avoid blindly replaying a hook after an uncertain response: reconcile deploy
metadata before deciding whether another trigger is needed. Capture failed job
status and safe log references; never print hooks or environment values.

Then run the persistent browser scenario in this repository against the same
recorded image, with read-only image checks before and after the scenario. Report
this as **post-deployment** verification. It does not replace existing source CI
or an isolated **pre-deployment** release-image test. On failure, keep the stable
rollout red and provide evidence; do not silently roll back or destroy resources.

## Configuration and approvals still needed

1. User provisions the paid services and intended admin, then provides the web
   URL and web/worker IDs. PostgreSQL 18, Valkey 8 and the Blueprint's resource
   plans should be confirmed on the actual deployment.
2. User chooses/enters the provider configuration securely on Render. Neither
   browser tests nor HTTP smoke need access to the provider credential.
3. Approve the exact GitHub environment and its nonsecret target variables;
   securely enter distinct web/worker hook URLs and a permitted Render metadata
   API credential. No credential should be copied from another environment.
4. Review/merge the stable deployment patch and explicitly enable automatic
   deployments. Merely preparing this proposal does not enable a live path.

## AI provider-switching decision (separate application change)

In v0.7.5, nonblank `OPENAI_ACCESS_TOKEN`, `OPENAI_URI_BASE` and `OPENAI_MODEL`
override saved `Setting` values in provider construction and health checks. The
existing provider tests explicitly assert ENV-over-Setting model precedence.
`Assistant::Builtin` uses that registry when processing replies. Web and worker
resolve their own process environments.

Pgvector embedding configuration is separate: `EMBEDDING_*` overrides the relevant
`OPENAI_*` environment fallback, and its token/URL currently do not fall back to
saved OpenAI settings. Hosted OpenAI vector storage does have ENV-over-Setting
fallback. Simply saving a new chat endpoint cannot prove embeddings switched.

Two concrete policies need product agreement:

- Preserve ENV as an operator lock, expose the effective source in the admin UI,
  and permit changes only for settings not locked by ENV. Operators remove ENV
  locks and restart both processes to switch to saved settings.
- Add an explicit opt-in admin-managed mode: use saved configuration with ENV
  only as initial/default values; preserve current precedence by default for
  existing deployments. Apply one resolver consistently to chat, provider health
  and the intended vector/embedding fallback, with separate explicit embedding
  overrides. Decide what clearing a saved credential means before implementing.

Regression evidence should use two local fake provider endpoints and dummy keys:
configure A, save B as admin, prove a *worker request* reached the expected endpoint
with the expected dummy auth, check web/worker health agrees, then restore only
that test's baseline. Test ENV lock mode and admin mode separately. Do not perform
this global provider-switching experiment against the shared sample app until
its policy and temporary impact are approved.
