# Optional integrations on Render

Deploy Sure first, then configure the integrations you want. OpenAI, SSO, SMTP,
PostHog, and Langfuse credentials are **not prerequisites for creating the Sure
services**. Environment groups are optional. The database/Redis connections,
Rails secret, self-hosted mode, HTTPS settings, and Puma process/thread tuning remain in the
Blueprint because they are infrastructure and runtime configuration.

This guide was checked against **Sure v0.7.5**. It distinguishes working UI setup
from features that still need operator configuration; it does not change Sure's
configuration precedence or promise a UI for every integration.

## Start in Sure's UI

### Chat / OpenAI-compatible providers

These steps configure built-in chat on No AI and Simple AI. External AI keeps
chat routed through AlphaClaw; its saved OpenAI settings support optional
OpenAI-backed background/PDF features instead.

1. Sign in with an account allowed to manage **Settings → Self-Hosting**
   (`/settings/hosting`). Select/configure your supported AI provider there.
2. In the OpenAI settings, enter the access token and model. For native OpenAI,
   the base URL can be left blank. For a compatible provider, enter its base URL
   and a model it supports. A nonblank base URL requires a model in v0.7.5.
3. The previous Blueprint model was `gpt-4o-mini`. Enter that explicitly if you
   want to retain it; leaving the model blank with native OpenAI uses Sure's
   default (`gpt-4.1` in v0.7.5), which can change cost and behavior.
4. Verify a chat request and the background AI operation you use. No OpenAI
   environment variables or Render environment group are required for this
   chat setup. The No AI profile also allows later UI configuration; its name
   describes the initial setup, not a permanent AI lockout.

The Blueprints omit `OPENAI_ACCESS_TOKEN`, `OPENAI_MODEL`, and `OPENAI_URI_BASE`.
A nonblank value supplied through the service environment (including a linked
group) still takes precedence over saved settings and disables the corresponding
UI field. This is deliberate operator control, not something the template can
reverse. See the [OpenAI UI](https://github.com/we-promise/sure/blob/v0.7.5/app/views/settings/hostings/_openai_settings.html.erb)
and [provider resolution](https://github.com/we-promise/sure/blob/v0.7.5/app/models/provider/registry.rb).

### Single sign-on

The SSO provider editor is at **Admin → SSO Providers** (`/admin/sso_providers`)
for authorized administrators. No SSO credentials or login-policy overrides are
included in these Blueprints, and local login is retained by default.

**Current v0.7.5 limitation:** saving a provider in the database is not enough to
activate it on a default production install. Production selects YAML/ENV
providers unless `AUTH_PROVIDERS_SOURCE=db` is set. To use database-backed
providers, opt into that flag on both Sure services and redeploy, then configure
and enable the provider in Admin. Follow the app's restart guidance and verify
an actual SSO login while keeping a working local admin session. Do not disable
local login until SSO is proven. Existing YAML/ENV providers should be migrated
and tested deliberately before switching source modes.

This is a current application gap in fully environment-free SSO activation; the
template does not silently change the authentication source or login policy.
See [FeatureFlags](https://github.com/we-promise/sure/blob/v0.7.5/lib/feature_flags.rb),
[ProviderLoader](https://github.com/we-promise/sure/blob/v0.7.5/app/services/provider_loader.rb),
and the [SSO editor](https://github.com/we-promise/sure/blob/v0.7.5/app/controllers/admin/sso_providers_controller.rb).

## Optional operator settings

### Environment groups or direct service variables

Use these only if you prefer environment-managed configuration, or a feature
below currently requires it. For OpenAI overrides, configure a matching
`OPENAI_ACCESS_TOKEN` and `OPENAI_MODEL`. Leave `OPENAI_URI_BASE` unset for native
OpenAI; only add it for a compatible/custom endpoint. In v0.7.5 even an explicit
OpenAI URL selects the custom-endpoint code path. Configure the same intended
settings on **both `sure-web` and `sure-worker`**:

- **With a group:** select or create a group scoped to this deployment, add the
  intended settings, then link it under each service's **Environment → Linked
  Environment Groups**. Keep demo/test and production groups separate. Check the
  project/environment scope, not just the name. Remove duplicate service-level
  entries only after verifying the intended group values and the migration below.
- **Without a group:** add the variables directly in each service's **Environment**
  settings. Use the same values on both. The worker no longer copies the OpenAI
  token from web; update both when rotating credentials or changing providers.

Save and deploy both services after the final change. Linking a group starts a
deploy; later removal of overrides requires a subsequent deploy. Verify the
latest web and worker deploys are live before testing. Blueprint syncs preserve
manually configured variables that the YAML omits.

Service-local values always override groups, even when the local value is blank.
Avoid multiple linked groups defining the same key: their precedence is not
guaranteed. See [Render's precedence rules](https://render.com/docs/configure-environment-variables#environment-groups).
Never put real tokens in YAML, Git, screenshots, issue comments, or logs.

### Embeddings and document search

Simple AI and External AI retain `VECTOR_STORE_PROVIDER=pgvector`,
`EMBEDDING_MODEL=text-embedding-3-small`, and `EMBEDDING_DIMENSIONS=1536`. These
are intentional profile choices, not chat credentials. Removing them would
change document storage/provider behavior and embedding dimensions; existing
pgvector users should keep their working model/dimensions aligned with stored
vectors. Do not remove or change them as part of the OpenAI override cleanup.

Document search is optional and need not be configured to start using Sure.
In v0.7.5, pgvector's embedding client reads `EMBEDDING_ACCESS_TOKEN` (falling
back to `OPENAI_ACCESS_TOKEN`) and `EMBEDDING_URI_BASE` (falling back to
`OPENAI_URI_BASE` and then OpenAI's endpoint) from ENV, not saved chat settings.
A chat token entered in the UI does **not** complete that embedding setup. If you
need this feature, separately configure embedding credentials/endpoint on both
services; using `EMBEDDING_*` avoids locking the chat UI fields. A compatible
provider must support the configured embedding model. Otherwise leave this
optional feature unused. See [VectorStore](https://github.com/we-promise/sure/blob/v0.7.5/app/models/vector_store.rb)
and its [registry](https://github.com/we-promise/sure/blob/v0.7.5/app/models/vector_store/registry.rb).

### External AI profile and MCP

External AI intentionally selects `ASSISTANT_TYPE=external` and wires Sure to
AlphaClaw using an internal URL and a generated shared gateway token. It also
keeps the generated MCP token and initial `MCP_USER_EMAIL` prompt, plus
AlphaClaw's own setup prompts. Those settings provision this selected profile;
this change does not disconnect its gateway or change it to built-in chat.

Sure's UI supports external assistant URL/token/model configuration when those
fields are not environment-managed. In this profile the wired URL/token and
assistant selection remain environment-managed. Redundant legacy agent/session
and empty allowlist defaults are omitted; Sure keeps its existing defaults, and
operators can deliberately override them. MCP's legacy shared-token/user mapping
is ENV-only in v0.7.5. See [external assistant configuration](https://github.com/we-promise/sure/blob/v0.7.5/app/models/assistant/external.rb)
and [MCP authentication](https://github.com/we-promise/sure/blob/v0.7.5/app/controllers/mcp_controller.rb).

### SMTP, PostHog, and Langfuse

These were already absent from the Blueprints and remain optional:

- **SMTP:** v0.7.5 reads mail delivery settings from ENV, without a matching
  administrator setup UI. Without valid mail settings, do not expect password
  reset, invitations, or other outgoing mail to work. Configure and test SMTP
  separately if needed; it is not a deploy-time prerequisite. See
  [production mail configuration](https://github.com/we-promise/sure/blob/v0.7.5/config/environments/production.rb).
- **PostHog / Langfuse:** operator analytics/tracing keys are optional; their
  clients are initialized only when the relevant credentials exist. They do not
  need to be added to the Blueprint or exposed through an end-user setup UI.
  This describes operator telemetry configuration, not a blanket assertion about
  every app feedback feature. See the
  [PostHog](https://github.com/we-promise/sure/blob/v0.7.5/config/initializers/posthog.rb)
  and [Langfuse](https://github.com/we-promise/sure/blob/v0.7.5/config/initializers/langfuse.rb) initializers.

## Existing deployments

**Removing a variable from YAML does not remove its deployed service value.**
Render preserves omitted variables, including the previously prompted web token,
worker token reference, literal model/endpoint defaults, and blank placeholders.
A Blueprint sync alone cannot unlock the UI or fix group inheritance.

1. Ensure the deployment's actual Blueprint branch contains the updated
   template, then sync it. Merging to `main` does not update the six deploy
   branches behind the README buttons. Maintainers must regenerate and publish
   all six with `scripts/update-deploy-branches.sh` for the repository's drift
   check to pass. First follow the [branch publication precautions](../README.md#branch-layout):
   Blueprint Auto Sync can apply live changes, including resetting manually
   changed template-managed settings. Web/worker plans are now omitted and
   therefore retained; datastore plans remain explicit (see [service sizing](../README.md#service-sizing)).
   Do not publish before that impact is approved or
   safely paused. Do not remove overrides while an older Blueprint can recreate them.
2. Before removing any OpenAI overrides, check whether pgvector currently uses
   them as embedding fallbacks. If it does, preserve the intended credentials
   **and endpoint** in explicit `EMBEDDING_ACCESS_TOKEN` / `EMBEDDING_URI_BASE`
   settings on both services. Verify them before cleanup. Keep the existing
   vector provider/model/dimensions and the External AI profile wiring.
3. Choose the intended source for the **three OpenAI settings**:
   - **Sure UI:** remove `OPENAI_ACCESS_TOKEN`, `OPENAI_MODEL`, and
     `OPENAI_URI_BASE` from both service settings and any linked group supplying
     them, then deploy both services and configure the UI. Do not remove keys
     from a shared group used by unrelated services; use a correctly scoped
     group or unlink it only after accounting for its other required settings.
   - **Environment group:** verify the intended group's values/scope and link
     it to both services, then remove those three direct service entries on
     both web and worker. Do not delete the values from the group itself.
   - **Direct service settings:** keep the working values and verify both
     services have the same intended settings. No group is required.
4. Save and deploy both services after the last environment change. Confirm
   both latest deploys are live and verify the affected UI and worker operations
   without printing tokens. For a staged rollout, verify the demo first, then
   repeat separately for the application/production deployment.

Old no-op placeholders may be removed only after checking their actual current
values; a once-blank variable may have been customized since deployment. Leave
unrelated settings alone. To roll back to environment-managed OpenAI settings,
restore the intended values on both services in Render and redeploy, not in Git.

`sync: false` is not a fix for inheritance: it only prompts at initial Blueprint
creation, is ignored on updates, is not copied to preview environments, and is
unsupported in environment groups. A prompted service value still overrides a
group. See [Render's Blueprint reference](https://render.com/docs/blueprint-spec#environment-variables).
