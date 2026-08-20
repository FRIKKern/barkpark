# refusal-placement-blast — re-derivation recipes (2026-08-08, self-host-blessing W1 verify)

Every load-bearing fact below re-derives from origin/main, never the worktree.

| claim | rerun |
|---|---|
| Two SECRET_KEY_BASE reads: media :522-524, endpoint :737-742; both presence-only | `git show origin/main:api/config/runtime.exs \| sed -n '515,532p;737,742p'` |
| Endpoint SKB read sits inside the prod block :696-:1024; media read is top-level with an inner prod gate | `git show origin/main:api/config/runtime.exs \| grep -n 'if config_env() == :prod do'` |
| Precedent shape (valid → bind, else prod-gated raise) at :38-46 | `git show origin/main:api/config/runtime.exs \| sed -n '38,46p'` |
| KEK case :187-216 — nil prod-raises, ANY set value (incl. "") configures LocalKek unvalidated | `git show origin/main:api/config/runtime.exs \| sed -n '187,216p'` |
| Base.decode64("") = {:ok,""}; "" \|\| :raised = "" | `elixir -e 'IO.inspect(Base.decode64("")); IO.inspect("" \|\| :raised)'` |
| config.exs dev KEK default decodes to exactly 32 bytes | `elixir -e 'Base.encode64(:crypto.hash(:sha256, "barkpark-dev-kek-not-for-prod")) \|> Base.decode64!() \|> byte_size() \|> IO.inspect'` |
| Only runtime-eval-time KEK setters are 4 test files, all base64(32B); CI sets none | `git grep -n 'BARKPARK_KEK' origin/main -- .github/ api/test/config/` |
| 4 runtime config tests eval runtime.exs with env: :prod and SKB = EXACTLY 64 bytes, PREVIEW_JWT = exactly 32 | `git grep -n 'String.duplicate("s", 64)\|String.duplicate("p", 32)\|env: :prod' origin/main -- api/test/config/` |
| CI test-run SKB is 67 bytes | `elixir -e 'byte_size("ci-secret-key-base-not-used-in-test-env-just-needs-64-chars-padding") \|> IO.inspect'` |
| Warm-image boxes mint SKB at EXACTLY the 64-byte floor (base64 of 48 random bytes) | `git show origin/main:deploy/bake-server-image.sh \| sed -n '145,152p'` |
| secrets.ex floors: SKB/PREVIEW 64B decoded (88-char env), KEK/CLOAK/HMAC 32B | `git show origin/main:api/lib/barkpark/release/secrets.ex \| grep -n '_bytes '` |
| PDS twin (bin/barkpark) boots MIX_ENV=prod and writes secrets via Release.Secrets — passes the new floors | `git show origin/main:bin/barkpark \| sed -n '57,100p'` |
| A runtime.exs raise on guerrilla surfaces at ecto.migrate → exit 13 → reset --hard OLD, active slot keeps serving | `git show origin/main:deploy/instance-deploy.sh \| sed -n '711,713p'` |
| Staging D4 env read (BARKPARK_ENV) is ALREADY MERGED at runtime.exs:73-81 — no pending collision | `git show origin/main:api/config/runtime.exs \| sed -n '68,81p'` |
| No open PR touches runtime.exs / api/Dockerfile / root compose (re-run at S1 merge time) | `for pr in $(gh pr list --state open --limit 60 --json number --jq '.[].number'); do gh pr view $pr --json number,files --jq 'select([.files[].path] \| map(test("api/config/runtime.exs\|api/Dockerfile\|^docker-compose.yml")) \| any) \| .number'; done` |
