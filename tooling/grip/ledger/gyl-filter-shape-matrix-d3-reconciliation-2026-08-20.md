# Re-derivation recipe — filter shape matrix (D3 vs Gyldendal's zero rows)

Verified 2026-08-20 against origin/main `a07a0baa138d628987706e94a31329379410f23a`
(worktree copies of `api/lib/barkpark/content/query.ex`,
`api/lib/barkpark_web/controllers/query_controller.ex` and
`api/test/barkpark_web/controllers/query_controller_filter_test.exs` are
byte-identical to origin/main — `git diff origin/main --stat -- <those>` is empty)
and against LIVE guerrilla.

## 1. The live shape matrix (L1 — running system)

    B="https://guerrilla.barkpark.cloud/v1/data/query/production/task?limit=100"
    for q in '' \
      'filter%5B%5D=a&filter%5B%5D=b' \
      'filter%5Bstatus%5D%5Beq%5D=published' \
      'filter%5Bstatus%5D%5Bcontains%5D=pub' \
      'filter%5Bzzz%5D=nope' \
      'filter%5Bdoc_id%5D%5BstartsWith%5D=task-' \
      'filter%5B_id%5D%5Bcontains%5D=task' \
      'filter%5Bstatus%5D%5Bbogus%5D=x' \
      'filter%5Btitle%5D%5Beq%5D%5B%5D=a' \
      'filter%5Btitle%5D%5Bgt%5D%5B%5D=a' \
      'filter%5B%24or%5D%5B0%5D%5Bstatus%5D=published' \
      'filter=zzz%3Dnope&filter=lifecycle_status%3Dopen' \
      'filter=lifecycle_status%3Dopen&filter=zzz%3Dnope' ; do
      printf '%-52s ' "${q:-<none>}"
      curl -s -o /dev/null -w '%{http_code} ' "$B&$q"
      curl -s "$B&$q" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(("count="+str(d["result"]["count"])) if "result" in d else ("ERR "+json.dumps(d["error"])[:130]))'
    done

Expected (measured 2026-08-20):
  <none>                           200 count=100
  filter[]=a&filter[]=b            200 count=100   <-- SILENT UNFILTERED (over-return)
  filter[status][eq]=published     200 count=100
  filter[status][contains]=pub     200 count=0     <-- SILENT WRONG-COLUMN (under-return)
  filter[zzz]=nope                 200 count=0     <-- unknown field -> real JSONB predicate, 0 rows
  filter[doc_id][startsWith]=task- 200 count=0     <-- wrong-column; column clause is `starts_with`
  filter[_id][contains]=task       200 count=0     <-- wrong-column via the _id->doc_id alias
  filter[status][bogus]=x          400 invalid_filter          (fail-closed guard, D75)
  filter[title][eq][]=a            400 internal_error Ecto.Query.CastError  <-- 500 dressed as 400
  filter[title][gt][]=a            400 invalid_filter          (@scalar_value_ops covers gt/gte/lt/lte only)
  filter[$or][0][status]=published 400 invalid_filter "unknown filter operator \"0\" on field \"$or\""
  filter=zzz=nope&filter=lc=open   200 count=100   <-- Plug duplicate-key LAST-WINS; first clause dropped
  filter=lc=open&filter=zzz=nope   200 count=0     <-- same mechanism, other order

## 2. The guard's blind spots (source-level, no DB needed)

The DB was saturated locally (`FATAL 53300 too_many_connections`), so run the
pure test and the probes WITHOUT the repo:

    cd api && MIX_ENV=test mix run --no-start -e \
      'ExUnit.start(autorun: false); Code.require_file("test/barkpark_web/controllers/query_controller_filter_test.exs"); ExUnit.run()'
    # => 30 tests, 0 failures

    cd api && MIX_ENV=test mix run --no-start -e '
      alias BarkparkWeb.QueryController, as: Q
      IO.inspect(Q.normalize_filter_map_for_test(["a","b"]))                       # %{}  <-- third silent path
      IO.inspect(Q.invalid_filter_op_for_test(%{"title" => %{"eq" => ["a"]}}))     # nil  <-- CastError shape
      IO.inspect(Q.invalid_filter_op_for_test(%{"status" => %{"contains" => "pub"}}))  # nil <-- wrong-column
      IO.inspect(Q.invalid_filter_op_for_test(%{"doc_id" => %{"startsWith" => "t"}}))  # nil <-- wrong-column
    '

## 3. The contrasting doctrine already shipped on a sibling route

    TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
    curl -s -H "Authorization: Bearer $TOK" \
      'https://guerrilla.barkpark.cloud/v1/tasks?limit=5&filter%5Bzzzz%5D=nope'
    # => 400 {"reason":"invalid_filter","message":"unknown filter key \"zzzz\" on GET /v1/tasks;
    #         supported: filter[kind], filter[label], filter[lifecycle_status],
    #         filter[parent], filter[parent_id], filter[phase_id], filter[type]"}

    curl -s -H "Authorization: Bearer $TOK" \
      'https://guerrilla.barkpark.cloud/v1/tasks?limit=20&filter%5Bparent_id%5D=task-3f1fe755ed53738e'
    # => 200, 9 docs, ALL parent_id=task-3f1fe755ed53738e
    # This REFUTES prior-art task `gr-bl-tasks-route-parent-filter-ignored`
    # ("returns an UNFILTERED page") on current main — a second decayed finding.

## Verdict carried by these runs

D3 ("unsupported filter DROPS the clause and returns the UNFILTERED set") is
HALF RIGHT and MISATTRIBUTED. Silent-unfiltered is reachable through exactly one
HTTP shape (a LIST-valued `filter` param). The zero rows Gyldendal reported twice
are the WRONG-COLUMN class: a VALID op on a COLUMN-backed field with no column
clause falls to the generic `content->>'field'` arm and matches nothing. Strictness
at `apply_field_op/4`'s catch-all does NOT reach that class — it needs a per-field
op capability table, i.e. the allowlist `/v1/tasks` already ships.
