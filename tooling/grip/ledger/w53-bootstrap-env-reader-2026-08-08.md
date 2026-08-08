# w53 [v-bootstrap-env-reader] — does bootstrap_env_encrypted reach a box?

Tree: `git archive origin/main` @ b402c0083225816a5be1b5b65d012e87e3a93532 → /tmp/w53i
Deps borrowed by symlink: `ln -s /Volumes/SATECHI/github/barkpark/cloud/deps /tmp/w53i/cloud/deps`

## Re-derivation recipes

1. Every non-test mention of the column (7 hits, all Elixir, zero Go):
   `cd /tmp/w53i && grep -rn 'bootstrap_env_encrypted\|put_bootstrap_env\|bootstrap_env' cloud/lib internal/ --include='*.ex' --include='*.go' | grep -v _test`

2. The single decrypting reader and its 3 callers:
   `cd /tmp/w53i && grep -rn 'reveal_bootstrap' --include='*.ex' . | grep -v /test/`
   → registry.ex:3462 (def), registry.ex:3578 wire_site_url (uses workspace/project/dataset only),
     vercel.ex:132 (env → Vercel project env vars), router.ex:3893 (GET /v1/barkparks/:id/bootstrap → owner JSON)

3. The env map's ORIGIN is the box, not the plane:
   `cd /tmp/w53i && sed -n '232,290p' internal/bootstrap/bootstrap.go`  (resolveEnv, Report.Env json:"env")
   then registry.ex:1545 put_bootstrap_env(boot["env"]) on the succeed report.

4. Worker JobSpec still has no Env field:
   `cd /tmp/w53i && sed -n '142,197p' internal/provisioner/worker.go`

5. The REAL box-env delivery mechanism (different column, different job kind):
   `cd /tmp/w53i && sed -n '14,18p;158,230p;300,310p' internal/provisioner/attach_domain.go`
   `cd /tmp/w53i && grep -rn 'attach_domain' cloud/lib/barkpark_cloud/registry.ex | head`

6. Green proof:
   `cd /tmp/w53i/cloud && CC=clang MIX_ENV=test mix test test/barkpark_cloud/bootstrap_template_test.exs`
   → `14 tests, 0 failures`
