# PDS wave 49 — npm repair deliverability: re-derivation recipes

Verifier assignment `repair-deliverability`. Every row below is a command that
re-derives the fact from scratch on a machine with `gh` authed to
FRIKKern/barkpark and network access to registry.npmjs.org. No npm login is
required for any row (that is itself one of the findings).

| # | Claim | Re-derivation command |
|---|---|---|
| 1 | `NPM_TOKEN` EXISTS as a repository-level secret, created 2026-04-19T08:16:53Z | `gh secret list` |
| 2 | It is NOT an environment secret — `Production` and `Preview` both list zero secrets (the cch-w30-s4 observation is TRUE) | `for e in Production Preview; do gh api "repos/:owner/:repo/environments/$e/secrets" -q '[.secrets[].name]\|join(",")'; done` |
| 3 | …and that is IRRELEVANT: neither consumer declares an `environment:`, so the repo-level secret resolves | `git show origin/main:.github/workflows/release.yml \| grep -n environment ; git show origin/main:.github/workflows/retag.yml \| grep -n environment` (no output) |
| 4 | release.yml HAS run with dry_run=false — 5 real publishes (4× 2026-04-19, 1× 2026-04-27), none since | `for id in 24627335562 24631668150 24632237354 24632572922 25019649888 25019575731 27313599383; do gh run view $id --json createdAt,conclusion,jobs -q '.createdAt+" "+([.jobs[].steps[]\|select(.name\|test("Publish"))\|.name+"="+.conclusion]\|join(" ; "))'; done` |
| 5 | The 2026-06-10 run (27313599383) took the DRY-RUN path; the REAL step is `skipped` | `gh run view 27313599383 --json jobs -q '.jobs[].steps[]\|select(.name\|test("Publish"))\|.name+"="+.conclusion'` |
| 6 | The last registry WRITE the token is known to have made is 2026-04-27T21:09:39Z (`@barkpark/core@1.0.0-preview.3`) — matches run 25019649888 at 21:08:20Z | `curl -s https://registry.npmjs.org/@barkpark%2fcore \| python3 -c "import sys,json;print(json.load(sys.stdin)['time'])"` |
| 7 | GH Actions logs for the April real publishes are GONE (HTTP 410) — the registry `time` field is the only surviving receipt | `gh run view 25019649888 --log` |
| 8 | The token secret is 40 bytes (last measured in CI 2026-06-10); length does NOT discriminate classic vs granular, so expiry is UNPROVEN | `gh run view 27313599383 --log \| grep "NPM_TOKEN present"` |
| 9 | **`npm publish --dry-run` does NOT exercise auth** — it succeeds with a bogus token, so release.yml:158's "so the auth path itself is exercised" is false and the 2026-06-10 green proves nothing about validity | `mkdir /tmp/p && cd /tmp/p && printf '{"name":"@barkpark/react","version":"1.0.0-preview.99"}' > package.json && printf '//registry.npmjs.org/:_authToken=npm_BOGUS…\n' > .npmrc && npm publish --dry-run --access public --tag preview` |
| 10 | …whereas `npm whoami` DOES hit the auth wall (E401 with a bogus token) — i.e. a one-line preflight would turn the presence-check into a measurement | (same dir) `npm whoami` |
| 11 | `npm access list packages @barkpark` prints `read-write` WITH NO CREDENTIALS — it is the public org endpoint, and therefore proves nothing about who is authorized | `npm whoami; npm access list packages @barkpark; curl -s https://registry.npmjs.org/-/org/barkpark/package` |
| 12 | This machine holds NO npm credential (`~/.npmrc` absent), so `npm deprecate` cannot be executed here by a human either | `ls -la ~/.npmrc ; npm whoami` |
| 13 | NO workflow can run `npm deprecate` — the only NPM_TOKEN consumers are release.yml (publish) and retag.yml (dist-tag add/rm) | `git grep -ln "npm deprecate" origin/main -- .github` (empty) |
| 14 | `@barkpark/react` has ONE maintainer (frikkern) and 34 downloads last week — two of npm's three unpublish conditions for an older package are MET | `curl -s https://registry.npmjs.org/@barkpark%2freact \| python3 -c "import sys,json;d=json.load(sys.stdin);print(d['maintainers'])" ; curl -s https://api.npmjs.org/downloads/point/last-week/@barkpark%2freact` |
| 15 | Neither published react version carries a `deprecated` field today | `curl -s https://registry.npmjs.org/@barkpark%2freact \| python3 -c "import sys,json;d=json.load(sys.stdin);print([(v,d['versions'][v].get('deprecated')) for v in d['versions']])"` |
| 16 | `@barkpark/react@1.0.0-preview.2` is FREE — the registry's max react version is preview.1, so a fix HAS a version to ship under | `curl -s https://registry.npmjs.org/-/package/@barkpark%2freact/dist-tags` |
| 17 | core + nextjs dist-tags are internally inconsistent (`latest`=preview.3, `preview`=preview.2) — exactly the two packages the 2026-04-27 real publish touched | `for p in core nextjs; do curl -s "https://registry.npmjs.org/-/package/@barkpark%2f$p/dist-tags"; echo; done` |

Policy citations (fetched 2026-08-05, not asserted from memory):
`https://docs.npmjs.com/policies/unpublish` — "Regardless of how long ago a
package was published, you can unpublish a package that meets all of the
following conditions: no other packages in the npm Public Registry depend on it,
it had less than 300 downloads over the last week, it has a single
owner/maintainer." and "Once `package@version` has been used, you can never use
it again."  `https://docs.npmjs.com/cli/v11/commands/npm-deprecate` — "You must
be the package owner to deprecate something."
