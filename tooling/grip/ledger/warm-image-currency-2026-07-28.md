# Re-derivation recipes — warm-image currency (claude-ready-servers wave 1, 2026-07-28)

Verifier lane `v-warm-image-currency`: what commit the newest `role=warm-image`
snapshot carries, whether `c65f517e2` is an ancestor of it, and when the two idle
pool boxes were created relative to the last bake. Read-only hcloud under the
FLEET context (`--context barkpark`); `unset HCLOUD_TOKEN` first (PDF-D75 Darwin
context-blindness — an exported token silently overrides `--context`).

| # | Claim | Command |
|---|---|---|
| 1 | Exactly TWO `role=warm-image` snapshots exist: 412729384 (2026-07-26T03:44:52Z, commit 92dec35a4) and 413101285 (2026-07-27T03:51:09Z, commit 2c8fe0da4) | `unset HCLOUD_TOKEN; hcloud --context barkpark image list -o json \| python3 -c "import sys,json;[print(i['id'],i.get('created'),i.get('description'),i.get('labels')) for i in json.load(sys.stdin) if (i.get('labels') or {}).get('role')=='warm-image']"` |
| 2 | The newest image's commit 2c8fe0da4 CONTAINS c65f517e2 | `git merge-base --is-ancestor c65f517e2 2c8fe0da467cd3772e250655352a25f7c5b68ee4 && echo CONTAINS \|\| echo PRE-FIX` |
| 3 | The previous image's commit 92dec35a4 is PRE-FIX (bake 03:44, fix landed 15:36 the same day) | `git merge-base --is-ancestor c65f517e2 92dec35a4b4b361b5f478c6e5fb44f7210c1a0f6 && echo CONTAINS \|\| echo PRE-FIX; git log -1 --format='%ci' c65f517e2` |
| 4 | Both idle pool boxes (warm-38f48c56 03:52:47Z, warm-228a3424 03:58:02Z) were created MINUTES AFTER the 2026-07-27 bake, FROM image 413101285 | `unset HCLOUD_TOKEN; for s in warm-38f48c56 warm-228a3424; do hcloud --context barkpark server describe $s -o json \| python3 -c "import sys,json;d=json.load(sys.stdin);i=d.get('image') or {};print(d['name'],d.get('created'),json.dumps(d.get('labels')),i.get('id'),i.get('description'))"; done` |
| 5 | muscle-1 (warm-eabbf4cc) runs the PRE-FIX image 412729384 / 92dec35a4, created 2026-07-26T13:47:49Z — before c65f517e2 was even committed | same as #4 with `warm-eabbf4cc` |
| 6 | c65f517e2 touches ONLY CLI + provisioner Go files — no bake script, so it CANNOT have removed the seed from the image lineage | `git show --stat c65f517e2 \| tail -10` |
| 7 | The bake boots FROM the newest snapshot and only fast-forwards git + rebuilds + migrates + strips SECRETS — it never resets Postgres data, so the seeded default workspace carries forward across every bake generation | `git show origin/main:deploy/bake-server-image.sh \| sed -n '111,170p'` (and `git show origin/main:scripts/deploy-rebuild.sh \| grep -i seed` → no hits) |
| 8 | The seed carriage is stated in-code as the reason the reset step exists (~27 demo docs, three live 2026-07-26 provision_support 409s) | `git show origin/main:internal/cli/cloud/support.go \| sed -n '214,226p'` |
| 9 | The reset step is gated on slug `default` only — a template-slug parent never exercises it | `git show origin/main:internal/cli/cloud/support.go \| grep -n 'SupportDefaultWorkspaceSlug' -A3` |
| 10 | The two idle pool boxes serve NO HTTP (ports 80/4000 both time out) — the seed cannot be confirmed by an anonymous read; muscle-1 does answer (80→308, 4000→200) | `for ip in 116.203.86.242 91.98.139.58 46.224.19.120; do curl -s -m 8 -o /dev/null -w "$ip:80=%{http_code} " http://$ip/; curl -s -m 8 -o /dev/null -w "4000=%{http_code}\n" http://$ip:4000/api/schemas; done` |
