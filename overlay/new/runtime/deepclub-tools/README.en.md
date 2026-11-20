# DeepClub mobile tools

[中文](README.md)

A directly loadable ESM plugin for DSH `0.2.2-rc.1` and Node 22.19+. The device's authenticated agent-config is the sole source of model inventory, endpoints and specifications. There is no model-name inference, model probing or manual API-key setup.

## Packaging and settings

Copy `src/`, `package.json`, `cordis.patch.yml` and the documentation/license into `/opt/dsh-go/deepclub-tools/`. This path belongs to the existing `/opt/dsh-go` engine upgrade transaction. Link its dependencies to the existing runtime:

```sh
ln -s /opt/dsh/node_modules /opt/dsh-go/deepclub-tools/node_modules
```

The plugin registration must belong to the profile. Before a normal Android engine launch, idempotently merge this single insertion into the guest `$DSH_HOME/profiles/web/cordis.patch.yml` (`/root/.dsh/profiles/web/cordis.patch.yml` on the local runtime). Place it before existing `deepclub-tools` configuration overrides and preserve the catalog and other settings:

```yaml
- insert:
    - id: deepclub-tools
      name: file:///opt/dsh-go/deepclub-tools/src/index.js
```

**Do not insert this plugin through a CLI `--patch`**, including passing this package's `cordis.patch.yml` to `dsh web --patch`. DSH applies bundle, profile, home and CLI patches in that order. A plugin inserted last by the CLI cannot receive an earlier profile configuration override, so `settings/mutate` rejects it with `Configuration for "deepclub-tools" is overridden by a home patch or command-line overlay`. Remove the old CLI insertion during migration; inserting the same ID in both layers creates duplicates.

On first launch, the profile patch can be created before the profile exists. DSH then initializes the official `web` profile and preserves the existing patch. Existing installations also need this registration check before normal startup: seeding only the rootfs is insufficient because engine upgrades preserve `/root` user data. Repeated launches should retain the correct existing registration and settings.

The package manifest still declares `dsh.bundle.patch` pointing to `cordis.patch.yml`. A profile may load it as a bundle layer, which precedes the writable profile settings layer and supports normal settings writes. Do not also insert that ID into the profile patch when using bundle registration. Android currently uses the profile patch registration described above.

The required services are `credentials`, `tools`, `fs`, `workingDirectory`, `sandboxPolicy`, `jobs`, `approval` and `systemPrompt`. The service exported by `dsh-user-approval` is named `approval`. Keep `dsh-tool-jobs` in the agent composition: an unavailable job controller rejects video creation before any paid POST.

The Schemastery `Config` has one volatile field, `catalog`. The settings namespace is the patch entry ID `deepclub-tools`. Write `{catalog: <complete agent-config>}` through `settings/mutate`; obtain `DEEPCLUB_API_KEY` through credentials, never through Config. On logout, clear catalog to `{models:[],tools:{}}` before removing the key. An empty `{}` is safe too.

The profile registration must also use the canonical `file:///` URL. Loader normalizes absolute paths to URLs; using that same name from the start lets ConfigEditor's generated override match the original entry. Both the canonical URL and registration in the correct profile layer are required.

Catalog and credential events immediately retire old registrations and task access. Execution, HTTP requests, file output and result retrieval additionally revalidate authorization and credentials. The production API origin is fixed to `https://deepclub.net`. Trusted in-process tests may inject `installDeepclubTools(ctx, config, {loopbackBaseURL: 'http://127.0.0.1:PORT'})`. The Android debug launcher may also set the engine environment variable `DEEPCLUB_TEST_ORIGIN=http://10.0.2.2:18453`. Only HTTP origins on `127.0.0.1`, `[::1]` or the emulator host `10.0.2.2` are accepted, without credentials, paths, queries or fragments. The catalog base must equal the production site or this exact injected origin. Config and tool arguments expose no test switch; production launch leaves the environment variable unset.

## Tools and approval

- `deepclub_generate_image`: the intersection of `tools.image_generation`, authorized image models and `/v1/images/generations`.
- `deepclub_edit_image`: `image_editing` and `/v1/images/edits`, with multipart reference uploads.
- `deepclub_generate_video`: `video`, selecting `/v1/videos` multipart or `/v1/video/generations` JSON from `media.video_protocol`. It acquires a real session-owned DSH job before the single submission, then polls with GET and downloads the result.
- `deepclub_get_result`: retrieves that session's job status and media card. Arbitrary upstream task IDs are not accepted, and retrieval does not create another paid task.
- `deepclub_embed`: `embedding` and `/v1/embeddings`; vectors are saved as a workspace JSON artifact instead of filling the model context.

Audio, rerank and web search are not registered in this release. A tool must select an authorized model and, when multiple specifications exist, a specification key. Size, quality, count, duration, ratios and reference limits come from that specification. The request sends its published parameters and resolution discriminator; the specification key itself is not an API request field.

`user_intent` must quote the latest real user message in the current session verbatim. This check does not replace understanding intent: the system prompt instructs the model to use each tool only for an explicit user request for that operation. Every paid call also goes through `ctx.approval.request`; only `allowed-once` proceeds. Approval describes the actual inputs, model, specification, files and billing uncertainty. Unknown prices are never reported as zero. POST requests are never retried, and there is no automatic endpoint or provider fallback.

References must be absolute workspace file paths explicitly mentioned by the user in the current request. The engine reads the files; URLs, guessed paths, directories and links escaping the workspace are refused. Mobile attachment IDs are not integrated yet: a selected workspace file path must be included in the request. Image/video results use the existing `dsh-go/media` v1 card metadata. Unparsed dimensions, duration and codecs are omitted.

## File and task boundaries

Output filenames are random `deepclub-UUID.ext` files in the session working directory. There is no model-supplied output path. Preflight and binary reservations use the real `fs/write-intent` and `fs.writeText(createIfAbsent)` gates. Binary data only fills the exact empty inode that was reserved, opened with `O_NOFOLLOW`, with repeated session, sandbox, directory and identity checks. JSON writes stay entirely within the engine's text API.

The binary adapter supports only a host filesystem with a verified identity mapping. Other backends fail closed. Like the DSH trusted-path model, these checks do not claim to defeat a malicious process with host write access racing ancestor replacement between checks and syscalls.

Responses have byte limits. API and download redirects are refused. Downloads never receive the device Bearer key, even on the API origin. DNS is checked at connection time to reject private, loopback and link-local destinations; only the explicitly injected test origin allows loopback HTTP. Errors never echo upstream response bodies, keys or signed URLs.

Jobs belong to the current Session object and authorization generation. Logout, credential rotation, catalog change, plugin disposal and session teardown invalidate old tasks. No recovery journal is persisted. `job_kill` stops local work only; it sends no upstream DELETE and never claims cancellation or a refund. Submitted work may continue upstream and be charged. Automatic recovery after engine restart is not implemented; resubmitting a generation is not a recovery mechanism.

## Verification

Use the existing rootfs dependencies or a temporary link to a pinned DSH dependency prefix; no dependency installation or update is required:

```sh
node --test runtime/deepclub-tools/test/*.test.mjs
```

Behavior tests use real DSH 0.2.2-rc.1 filesystem, Session, Agent registry and job services with a loopback HTTP server, synthetic credentials and controlled approval replies. They cover authorization, endpoints/specifications, denied approval, sandbox/path boundaries, multipart requests, no POST retry, embeddings, both video protocols, session isolation, cancellation, logout and live configuration/credential changes. The settings regression tests exercise the actual profile patch, ConfigEditor, Settings and Loader. They contrast a CLI overlay insertion, whose settings write is refused without changing disk or live configuration, with profile registration, whose namespace supports volatile updates without recreating the plugin and removes tools when catalog is cleared. Missing disabled plugin IDs are also covered. Services that perform I/O use stand-ins.

Android installation, PRoot loading, native approval UI and real paid endpoints require integration validation. Desktop Node tests do not replace those checks.

## Source and license

The MIT-declared `@deepclub/dsh-media-tools` package in `meyaomiao/deepclub-desktop@b9719c4` was inspected. Its `overlay/new/packages/deepclub/media-tools/src/media-client.ts` and `output.ts` were adapted for bounded transport, no POST retry, signature checks and engine-backed binary reservations. Desktop settings/public-catalog caching/default inventory were replaced with device authorization, session jobs and per-operation approval. No desktop UI, Whaleness gateway or gateway dependency was copied. The dsh-media API, approval contract and media metadata at dsh-Go `288234a` were also checked; this plugin does not depend on the old media plugin. Attribution, modifications and the MIT text are in `LICENSE`.
