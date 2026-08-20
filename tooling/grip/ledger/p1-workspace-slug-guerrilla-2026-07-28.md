# P1 workspace slug — a Guerrilla-parented provision_support pins `"default"` (2026-07-28, verifier v-p1-workspace-slug)

**Verdict: the c65f517e2 reset bracket RUNS.** A `provision_support` job whose parent is the
`Guerrilla` main claims `workspace: "default"`, so `resetDefault` is TRUE in the Go worker chain
and the reset + double re-mint bracket executes. P1 is therefore a genuine test of c65f517e2's
fix, not a re-confirm of a template-slug path.

| Link in the chain | Fact | Re-derivation command |
|---|---|---|
| CP claim map | `workspace: parent && (parent.bootstrap_workspace \|\| "default")` — router.ex:9471 (added by `928e37a38`, "support-provision claim defaults workspace when parent has no bootstrap_workspace") | `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| sed -n '9460,9478p'` |
| No caller override | `POST /v1/fleet/supports` mode=provision accepts only `name`, `barkpark_id`/`parent_id`, `server_type` — no workspace param anywhere on the enqueue path | `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| sed -n '1958,1990p'` |
| Guerrilla is template-less | `GET /v1/barkparks/b2b81e69-…/bootstrap` → **404 `no_bootstrap`**; `reveal_bootstrap/1` returns `{:ok, nil}` only when `bootstrap_workspace` AND `bootstrap_read_token_encrypted` are BOTH nil ⇒ `bootstrap_workspace == nil` live | `TOK=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['cloud_token'])"); curl -s -H "Authorization: Bearer $TOK" https://api.barkpark.cloud/v1/barkparks/b2b81e69-c79c-4eff-b6d7-84507d15b925/bootstrap` |
| Go gate constant | `const SupportDefaultWorkspaceSlug = "default"` (internal/cli/cloud/support.go:227); gated in BOTH chains — provisioner/support.go:671, cloud_support_cmd.go:658 | `git grep -n 'SupportDefaultWorkspaceSlug' origin/main -- internal` |
| Claim decode | `Workspace string \`json:"workspace"\`` (internal/provisioner/support.go:182); `validateSupportSpec` requires a slug-shaped value — `"default"` passes, `""` is the death 928e37a38 fixed | `git show origin/main:internal/provisioner/support.go \| sed -n '178,186p;970,978p'` |
| Deploy currency | `928e37a38` and `c65f517e2` are both ancestors of `78209d8e4` (the CP-deployed commit per the Digest) and of `origin/main` | `git merge-base --is-ancestor 928e37a38 78209d8e4 && echo YES` |
| Export target exists | Guerrilla live workspaces: `default` (Default Workspace) + `gyldendal` — `exportDatasetTar` GETs `/api/workspaces/default/export`, so the parent side of the chain is viable | `T=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])"); curl -s -H "Authorization: Bearer $T" https://guerrilla.barkpark.cloud/api/workspaces` |

**Experiment identity.** c65f517e2's own message: "Template-slug imports are unaffected; only the
ws=\"default\" fallback (template-less parents) hits it." The 2026-07-24 failure era
(task-63a199c0a0ce2a06, task-2ba0270056e7da6e) was a TEMPLATE main (astro-search-starter, ws slug
= template slug); the 2026-07-26 era was the ws=default fallback. Firing P1 on Guerrilla
reproduces the 07-26 class exactly — the class c65f517e2 targets.

**Residual risks (not settled by this row):** the CP must hold a decryptable admin token for
Guerrilla or the enqueue 409s `no_admin_token` before any job exists (read-only probe not
available); and the deployed CP/provisioner build was inherited from the Digest, not re-proven
here (no CP version endpoint exists).
