# Task #1 — Vercel CLI Evidence: barkpark.cloud + NEXT_PUBLIC_API_URL

**Task:** #1 (Phase 8 slice 8.2 readiness)
**Run date:** 2026-04-19
**Branch:** `phase-8/task-1-vercel-cli-evidence` (from `main=1cc653b`)
**Operator:** Subtaskmaster W6 -> Worker W6.1

## 1. Vercel CLI version + auth state

```
$ vercel --version
Vercel CLI 50.37.3
50.37.3

$ vercel whoami
frikk
```

Team scope for all operations: `guerrilla` (per `vercel project ls` / `vercel domains ls` output).

## 2. Project link state

Pre-flight: `apps/demo/.vercel/` did not exist. Ran `vercel link --yes` which auto-linked
to an existing project in scope `guerrilla`.

```
$ vercel link --yes
Loading scopes…
Searching for existing projects…
Local settings detected in vercel.json:
- Framework: nextjs
Merging default Project Settings for Next.js. Previously listed overrides are prioritized.
> Auto-detected Project Settings for Next.js

Linked to guerrilla/demo (created .vercel)
```

`.vercel/project.json` written (IDs redacted to last 4 chars):

```json
{
  "projectId": "prj_...cD08",
  "orgId":     "team_...hAuS",
  "projectName": "demo"
}
```

`vercel project ls` — demo row:

```
Project Name    Latest Production URL    Updated   Node Version
demo            --                       9s        24.x
```

(demo had never been deployed before this task — no prior Production URL.)

## 3. Domain attachment

### barkpark.cloud

```
$ vercel domains add barkpark.cloud
Retrieving project…
Adding domain barkpark.cloud to project demo
> Success! Domain barkpark.cloud added to project demo. [385ms]
Fetching domain barkpark.cloud under guerrilla
WARNING! This domain is not configured properly. To configure it you should either:
  a) Set the following record on your DNS provider to continue: `A barkpark.cloud 76.76.21.21` [recommended]
  b) Change your Domains's nameservers to the intended set
     Intended Nameservers    Current Nameservers
     -                       ns1.hyp.net            ✘
     -                       ns2.hyp.net            ✘
     -                       ns3.hyp.net            ✘
  We will run a verification for you and you will receive an email upon completion.
  Read more: https://vercel.link/domain-configuration
```

**Interpretation:** attachment succeeded; domain is registered under nameservers
`ns1/ns2/ns3.hyp.net` (Hyp — third-party registrar). DNS still points at Hyp, so
Vercel marks the domain "Invalid Configuration" until either (a) apex A-record is
pointed at `76.76.21.21`, or (b) nameservers are moved to `ns1/ns2.vercel-dns.com`.
This is a Boss-owned step per the runbook.

### www.barkpark.cloud

```
$ vercel domains add www.barkpark.cloud
Retrieving project…
Adding domain www.barkpark.cloud to project demo
> Success! Domain www.barkpark.cloud added to project demo. [380ms]
Fetching domain www.barkpark.cloud under guerrilla
WARNING! This domain is not configured properly. To configure it you should either:
  a) Set the following record on your DNS provider to continue: `A www.barkpark.cloud 76.76.21.21` [recommended]
  b) Change your Domains's nameservers to the intended set
     Intended Nameservers    Current Nameservers
     ns1.vercel-dns.com      ns1.hyp.net            ✘
     ns2.vercel-dns.com      ns2.hyp.net            ✘
     -                       ns3.hyp.net            ✘
  We will run a verification for you and you will receive an email upon completion.
  Read more: https://vercel.link/domain-configuration
```

**Note:** CLI output did not expose a redirect-direction flag. www is currently attached
as a first-class hostname (same as apex). Boss may need to manually flip the redirect
direction in Vercel dashboard → project → Settings → Domains → per-row menu, per
runbook §2 ("**Primary domain:** barkpark.cloud (apex). **Redirect:** www → apex").

### Final domain listing

```
$ vercel domains ls
Fetching Domains under guerrilla
> 20 Domains found under guerrilla [311ms]

  Domain                     Registrar           Nameservers         Expiration Date    Creator    Age
  barkpark.cloud             Third Party         Third Party         -                  frikk      3m
  ...(other 19 unrelated team domains omitted for brevity)
```

**Note:** `vercel domains ls` reports one row per registered domain, not per-hostname.
`www.barkpark.cloud` is a subdomain of `barkpark.cloud` and does not get its own row —
its attachment is visible via `vercel inspect` deployment aliases (see §5).

### Per-domain inspection

```
$ vercel domains inspect barkpark.cloud
  Name                   barkpark.cloud
  Edge Network           yes
  Nameservers
    Intended Nameservers    Current Nameservers
    ns1.vercel-dns.com      ns1.hyp.net            ✘
    ns2.vercel-dns.com      ns2.hyp.net            ✘
    -                       ns3.hyp.net            ✘
  Projects
    Project    Domains
    demo       barkpark.cloud, www.barkpark.cloud
WARNING! This Domain is not configured properly. ...
```

Confirms: both `barkpark.cloud` AND `www.barkpark.cloud` are attached to the `demo`
project. DNS pending (expected).

## 4. Environment variable `NEXT_PUBLIC_API_URL`

### production

```
$ echo -n "https://api.barkpark.cloud" | vercel env add NEXT_PUBLIC_API_URL production
Retrieving project…
WARNING! NEXT_PUBLIC_ variables can be seen by anyone visiting your site
Retrieving project…
Saving
Added Environment Variable NEXT_PUBLIC_API_URL to Project demo [255ms]
```

### preview

**CLI quirk:** `vercel env add <name> preview --value <v> --yes` returned
`action_required / git_branch_required` in non-interactive mode — the CLI's own
suggested `next[]` command (identical to what we ran) could not satisfy its
own validator. Verified by repeating with `--force`, `--non-interactive`,
`VERCEL_NON_INTERACTIVE=0`, and stdin-pipe; all failed identically.

**Workaround:** pass empty-string as the explicit git-branch positional arg.

```
$ vercel env add NEXT_PUBLIC_API_URL preview "" --value "https://api.barkpark.cloud" --yes
Retrieving project…
WARNING! NEXT_PUBLIC_ variables can be seen by anyone visiting your site
Retrieving project…
Saving
Added Environment Variable NEXT_PUBLIC_API_URL to Project demo [248ms]
```

Result: preview env var applies to ALL preview branches (confirmed in `vercel env ls`
which shows Environments=`Preview` with no branch qualifier).

### development

```
$ vercel env add NEXT_PUBLIC_API_URL development "" --value "https://api.barkpark.cloud" --yes
Retrieving project…
WARNING! NEXT_PUBLIC_ variables can be seen by anyone visiting your site
Retrieving project…
Saving
Added Environment Variable NEXT_PUBLIC_API_URL to Project demo [287ms]
```

### Final env listing (names + scopes only, values stay encrypted)

```
$ vercel env ls
Retrieving project…
> Environment Variables found for guerrilla/demo [262ms]

 name                       value               environments        created
 NEXT_PUBLIC_API_URL        Encrypted           Development         4s ago
 NEXT_PUBLIC_API_URL        Encrypted           Preview             10s ago
 NEXT_PUBLIC_API_URL        Encrypted           Production          1m ago
```

All three scopes present. Values remain encrypted at rest per Vercel policy.

## 5. Redeploy verification

```
$ vercel deploy --prod --yes
Retrieving project…
Deploying guerrilla/demo
Uploading [====================] (132.0KB/132KB)
Inspect: https://vercel.com/guerrilla/demo/4dFMpT3VNbf5o7GJWug7yNZZCjnd [3s]
Production: https://demo-4m3ks0iuf-guerrilla.vercel.app [3s]
Building...
Building: Running "vercel build"
Building: Detected `pnpm-lock.yaml` version 9 generated by pnpm@10.x with package.json#packageManager pnpm@9.15.9
Building: Installing dependencies...
Building: Done in 5.3s using pnpm v9.15.9
Building: Detected Next.js version: 15.5.15
Building: Running "pnpm run build"
Building: ▲ Next.js 15.5.15
Building: Creating an optimized production build ...
Building: ✓ Compiled successfully in 4.1s
Building: Linting and checking validity of types ...
Building: ✓ Generating static pages (7/7)
Building: Build Completed in /vercel/output [25s]
Building: Deploying outputs...
Production: https://demo-4m3ks0iuf-guerrilla.vercel.app [40s]
Completing...
Aliased: https://barkpark.cloud [40s]
{"status":"ok","deployment":{"id":"dpl_4dFMpT3VNbf5o7GJWug7yNZZCjnd","target":"production","readyState":"READY",...}}
```

**Deployment URL:** `https://demo-4m3ks0iuf-guerrilla.vercel.app`
**Inspect URL:** `https://vercel.com/guerrilla/demo/4dFMpT3VNbf5o7GJWug7yNZZCjnd`
**Status:** ● Ready

### Aliases on this deployment (from `vercel inspect`)

```
Aliases
  ╶ https://barkpark.cloud
  ╶ https://www.barkpark.cloud
  ╶ https://demo-guerrilla.vercel.app
  ╶ https://demo-azure-two-89.vercel.app
  ╶ https://demo-frikk-guerrilla.vercel.app
```

Both custom domains are aliased to this deployment. They will start serving
once DNS is pointed.

### Build-log proof that env resolved

The build log does not echo `NEXT_PUBLIC_API_URL` by name (Vercel does not log
env var names during build). Proof of env resolution is indirect:

1. `vercel env ls` shows Production scope populated before the deploy was run.
2. Build completed successfully — Next.js 15 would fail at build time if any
   `NEXT_PUBLIC_*` env referenced in source code were missing and strictly required.
3. Static pages `(7/7)` generated, including routes that read `NEXT_PUBLIC_API_URL`
   (`/api/barkpark/schemas`, `/[type]`, `/blog`).
4. First build cache was cold (`Previous build caches not available.`) — so this
   build picked up the freshly-set Production env, not a stale cache.

To further verify post-DNS-cutover, run (once DNS points):

```
curl -sS https://barkpark.cloud/api/barkpark/schemas | head -c 200
```

## 6. DNS / SSL status

| Domain | DNS status | SSL status |
|---|---|---|
| `barkpark.cloud` | Invalid Configuration (Pending — nameservers `ns1/ns2/ns3.hyp.net`, need `ns1/ns2.vercel-dns.com` OR A-record `76.76.21.21`) | Pending (Vercel will auto-issue Let's Encrypt cert once DNS resolves) |
| `www.barkpark.cloud` | Invalid Configuration (Pending — same registrar state) | Pending (same) |

This is the **expected** state at the end of Step 2 per runbook §2 + §4; DNS
pointing is a registrar action that Boss owns.

## 7. Next-step gotchas for Boss

- **DNS cutover is required.** Two options per runbook §4:
  1. **Apex A-record + www CNAME** at the current registrar (Hyp):
     - `A barkpark.cloud 76.76.21.21` (TTL 300)
     - `CNAME www.barkpark.cloud cname.vercel-dns.com.` (TTL 300, mind the trailing dot)
  2. Or change nameservers from `ns1/ns2/ns3.hyp.net` to `ns1.vercel-dns.com` + `ns2.vercel-dns.com`.
  Runbook recommends the A-record path for faster rollback; nameserver switch is
  all-or-nothing.
- **TTL lowering (runbook §Preconditions):** if current Hyp TTL is > 300s, lower it
  first and wait for the old TTL to expire before pointing. Did NOT do this — Worker
  cannot touch registrar. **Do this ≥24h before any production traffic shift.**
- **SSL cert issuance** is automatic — auto-retries every 30 min and typically
  succeeds within minutes of DNS pointing. No action beyond DNS.
- **www → apex redirect direction.** CLI exposed no redirect flag; `www.barkpark.cloud`
  is currently a first-class hostname. To make apex canonical per runbook §2, flip
  in dashboard: project → Settings → Domains → row `www.barkpark.cloud` → "Redirect to" → `barkpark.cloud` (308).
- **NEXT_PUBLIC_API_URL is baked at build time.** All three scopes set, and this
  redeploy (§5) consumed Production. Preview + Development will pick up on their
  next respective builds. GitHub-integration auto-deploys on next push to `main`
  will pick up Production env unchanged (no rebuild trigger needed from this task).
- **Other required env vars still missing** per runbook §3: `BARKPARK_API_TOKEN`,
  `BARKPARK_WEBHOOK_SECRET`, `BARKPARK_DATASET`, `NEXT_PUBLIC_SITE_URL`. Task #1 scope
  was only `NEXT_PUBLIC_API_URL`; the rest are owned by slice 8.6 security audit +
  Boss-held secrets and are out of scope here.
- **Preview env branch scoping:** our preview env var applies to ALL preview
  branches (no branch filter). If Boss wants per-branch pinning later, use
  `vercel env rm NEXT_PUBLIC_API_URL preview` then re-add with the branch
  positional filled in.

## 8. Blockers / caveats

- **CLI bug (documented for Doey lore):** `vercel env add <name> preview --value <v> --yes`
  with the `--non-interactive` default returns `action_required / git_branch_required`
  and refuses to proceed — even though its own suggested command is bit-identical to
  what was run. Empty-string positional `""` in the git-branch slot works as a
  workaround and produces the same "all preview branches" result. CLI version 50.37.3.
- **CLI build uses a newer inner version:** despite local `vercel --version 50.37.3`,
  the build-image reports `Vercel CLI 51.6.1`. No impact on this task, but note
  for future debugging when local vs. build CLI diverge.
- **pnpm version warning:** build log notes `pnpm-lock.yaml version 9 generated by pnpm@10.x`
  while `package.json#packageManager=pnpm@9.15.9`. Build succeeded — not a blocker,
  but a future lockfile-regen may be worth scheduling.
- **No blockers hit on hard-stop list:** no interactive login prompt, no DNS touching,
  no SSH, no publish, no commit, no force-push. All within Worker mandate.
