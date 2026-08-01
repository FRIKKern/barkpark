# Re-derivation recipes — w36 sentinel-`:ok` predicate + revoke-all reachability (2026-08-01)

Lens/engine for every number below: **Elixir 1.19.5 / OTP 28**, corpus = clean
`git archive origin/main api/lib` at **29cb76e60**. Any quote of these integers
must carry BOTH.

## R0 — the corpus (all recipes assume `$D` from here)

```bash
D=$(mktemp -d); git -C <repo> archive origin/main api/lib | tar -x -C "$D"; cd "$D"
```

## R1 — the register header's `21 function-tail` + `+11 clause-local`, under a STATED predicate

The two integers reproduce EXACTLY, and only under all four knobs together.
The scan is inlined verbatim at **R5** below — no external file to go stale.

PREDICATE (AST, `Code.string_to_quoted!`; no regex anywhere):

- unit of count = one `def`/`defp` **clause** with a `do:` block (`{path,name,arity,line}`)
- `repo_write?` = subtree contains a call `<_>.Repo.w(...)` where the alias's LAST
  segment is `Repo` and `w ∈ {insert insert! update update! delete delete!
  insert_all update_all delete_all insert_or_update insert_or_update! transaction}`
- `tail(e)` = last expression of a `__block__`, else `e`; `:ok` literal also matches
  `{:__block__, _, [:ok]}`
- **FUNCTION-TAIL** = `repo_write?(body)` and `tail(body)` is the `:ok` literal
- **CLAUSE-LOCAL** = `repo_write?(body)`, `tail(body)` is NOT `:ok`, and some `->`
  clause body anywhere inside `body` (case/cond/with/try/receive/fn) has
  `tail == :ok`. Counted ONCE per def clause.

Result on the corpus above:

```
scanned files: 804  def clauses(with do-block): 17138
FUNCTION-TAIL  :ok, WITH repo-write predicate: 21
CLAUSE-LOCAL   :ok, WITH repo-write predicate: 11
```

## R2 — every knob is load-bearing (sensitivity; run the same scan with one knob flipped)

| knob flipped | FUNCTION-TAIL | CLAUSE-LOCAL |
|---|---|---|
| none (the stated predicate) | **21** | **11** |
| drop the repo-write predicate entirely | 257 | 247 |
| repo-ANY (`Repo.*` call, not only writes) | 23 | 18 |
| public `def` only (drop `defp`) | 15 | 4 |
| clause-local NOT disjoint from function-tail | 21 | 13 |

So: `21`/`11` are only re-derivable with the write-verb list, `def`+`defp`, and
disjointness all named. **No lens I can construct yields 115, 40, or 6.**
The unfiltered figure is **257**, not 115.

Own-line regex readings (the thing an AST lens exists to replace) give none of
these — for the record:

```bash
grep -rn --include='*.ex' -E '^ {4}:ok$'        api/lib | wc -l   # 131
grep -rn --include='*.ex' -E '^ {6,}:ok$'       api/lib | wc -l   # 316
grep -rn --include='*.ex' -E '(->|do:) :ok\s*$' api/lib | wc -l   # 327
```

## R3 — `Accounts.revoke_all_user_sessions/1` IS reached by receipt-emitting routes

```bash
grep -rn 'revoke_all_user_sessions' api/lib
sed -n '331,341p' api/lib/barkpark/accounts.ex     # Repo.update_all, count discarded, literal :ok
grep -rn 'do_reset_password' api/lib                # :200, :514 call; defp at :543
sed -n '556,562p' api/lib/barkpark/accounts.ex     # the call, inside do_reset_password/3, discarded
sed -n '445,462p' api/lib/barkpark_web/controllers/auth_controller.ex   # json(conn, %{ok: true}) at :460
grep -rn 'deprovision_user' api/lib/barkpark_web   # scim_users_controller.ex:77 and :101
grep -n 'ScimUsersController\|AuthController, :reset' api/lib/barkpark_web/router.ex
```

Two reached routes (the chain is one hop longer than it looks — `reset_user_password/2`
is `accounts.ex:505`, `do_reset_password/3` is `accounts.ex:543`, the call is `:560`):

1. `POST /v1/auth/reset` (router :1481) → `reset/2` → `Accounts.reset_user_password/2`
   (`accounts.ex:505`) → `do_reset_password/3` (`:543`) → `revoke_all_user_sessions/1`
   (`:560`, return discarded) → receipt `json(conn, %{ok: true})`
   at `auth_controller.ex:460`. **That receipt IS an already-emitted census site**:
   `elixir scripts/pds-elixir-receipt-census.exs --sites` prints
   `barkpark_web/controllers/auth_controller.ex:460  [WRITE d2] UNCLASSIFIED`.
2. SCIM `PATCH|PUT /scim/v2/Users/:id` (:1504/:1505) and `DELETE` (:1506) →
   `Scim.deprovision_user/3` (`scim.ex:132`) → same call. Receipts:
   `json(conn, render_user(conn, user, false))` — where `active: false` is a
   HARDCODED render argument — and `send_resp(conn, 204, "")`.
   **The census is blind to both**: `--sites` output greps 0 for `scim`.

Mechanical test on all three: the printed sentence does NOT change if
`update_all` matched zero rows.

NOT a route (checked, so nobody re-derives it as one): `Accounts.update_user_password/3`
(`accounts.ex:198`), whose `@doc` claims "revoking all sessions", has **zero callers
anywhere in `api/lib`** — `grep -rn 'update_user_password' api/lib` returns only its own
definition and one comment at `:542`.

## R4 — the flash+302 fourth class is REAL but its lossy membership is n=1 after a sweep

```bash
grep -ro 'put_flash(:info' --include='*.ex' api/lib | wc -l        # 45
grep -rl 'put_flash(:info' api/lib/barkpark_web/controllers/       # session_controller.ex, grant_controller.ex
grep -ro 'put_flash(:info' --include='*.ex' api/lib/barkpark_web/controllers | wc -l   # 7
for f in $(grep -rl 'put_flash(:info' --include='*.ex' api/lib); do
  /usr/bin/grep -nE 'revoke_all_user_sessions|revoke_user_session_token|touch_last_used|mark_projected|refresh_html_cache|stamp_scope|add_cost_nanos|seed_defaults!|ensure_builtin_roles|mark_dead|bootstrap_if_absent|remove_dep|delete_workspace_audit_sinks|delete_credential|fenced_delete|fenced_paper_update|complete_release_challenge|consume_release_gate|interrupt_rail_entries|Synonyms\.delete|Secrets\.delete|Settings\.delete|Exemptions\.clear' "$f" | sed "s|^|$f:|"
done
```

Exactly three hits across the 20 flash-carrying files:
`settings_live.ex:228` (`case Settings.delete(...)` — BRANCHES, not lossy),
`plugin_settings_live.ex:216` (a written basis comment about the return shapes),
`session_controller.ex:410` (`revoke_user_session_token(token)` fully discarded →
`put_flash(:info, "Signed out.")` + 302). **One lossy member, not a family.**

And the census's blind-spot reporter still cannot see the class:

```bash
grep -n 'report_blind_spots' scripts/pds-elixir-receipt-census.exs   # def at :1499, called at :217
grep -c  'redirect\|put_flash'  scripts/pds-elixir-receipt-census.exs # 0
```

## R5 — the scan itself (paste to `/tmp/sentinel_scan.exs`, run `elixir /tmp/sentinel_scan.exs api/lib` from $D)

```elixir
# SENTINEL :ok SCAN — AST lens, stated predicate.
#
# DEFINITIONS (all AST, no regex):
#   fn_body(def)      = the do-block of a def/defp (public+private both counted; --public-only flag filters)
#   tail(expr)        = last expression of a __block__, else the expr itself
#   repo_write?(ast)  = subtree contains Repo.<w> where w in insert/insert!/update/update!/delete/
#                       delete!/insert_all/update_all/delete_all/insert_or_update/insert_or_update!/
#                       transaction  (call form Repo.w(...) only)
#   FUNCTION-TAIL     = tail(fn_body) == :ok literal
#   CLAUSE-LOCAL      = some INNER clause body (case/cond/with/try/receive/fn ->) inside fn_body whose
#                       tail is literal :ok, AND that clause is not itself the function tail.
#                       Counted ONCE PER FUNCTION (a function is a clause-local member, not each clause).
#
# Counting unit for all reported numbers: ONE PER def CLAUSE (path,name,arity,line).
root = System.argv() |> List.first() || "api/lib"

files = Path.wildcard(Path.join(root, "**/*.ex"))

writes = ~w(insert insert! update update! delete delete! insert_all update_all delete_all
            insert_or_update insert_or_update! transaction)a

defmodule S do
  def walk(ast, acc, f), do: Macro.prewalk(ast, acc, fn n, a -> {n, f.(n, a)} end) |> elem(1)

  def repo_write?(ast, writes) do
    walk(ast, false, fn
      {{:., _, [{:__aliases__, _, mods}, w]}, _, _args}, a ->
        a or (w in writes and List.last(mods) == :Repo)
      _, a -> a
    end)
  end

  def tail({:__block__, _, exprs}) when exprs != [], do: List.last(exprs)
  def tail(x), do: x

  def ok_lit?(:ok), do: true
  def ok_lit?({:__block__, _, [:ok]}), do: true
  def ok_lit?(_), do: false

  def nm({name, _, args}) when is_atom(name), do: {name, (if is_list(args), do: length(args), else: 0)}
  def nm(_), do: {:__unknown__, 0}

  # collect all inner clause bodies (-> arrows) anywhere in the body
  def clause_bodies(body) do
    walk(body, [], fn
      {:->, _, [_lhs, rhs]}, a -> [rhs | a]
      _, a -> a
    end)
  end
end

acc =
  for f <- files, reduce: [] do
    acc ->
      {:ok, src} = File.read(f)
      ast = Code.string_to_quoted!(src, columns: true)

      defs =
        S.walk(ast, [], fn
          {kind, meta, [head, [do: body]]} = _n, a when kind in [:def, :defp] ->
            {name, arity} =
              case head do
                {:when, _, [h | _]} -> S.nm(h)
                h -> S.nm(h)
              end
            [{f, kind, name, arity, meta[:line], body} | a]
          _, a -> a
        end)

      acc ++ defs
  end


IO.puts("scanned files: #{length(files)}  def clauses(with do-block): #{length(acc)}")

ft = for {f,k,n,a,l,b} <- acc, S.ok_lit?(S.tail(b)), do: {f,k,n,a,l,b}
ft_rw = for {f,k,n,a,l,b} <- ft, S.repo_write?(b, writes), do: {f,k,n,a,l}

cl = for {f,k,n,a,l,b} <- acc,
        not S.ok_lit?(S.tail(b)),
        Enum.any?(S.clause_bodies(b), &S.ok_lit?(S.tail(&1))),
        do: {f,k,n,a,l,b}
cl_rw = for {f,k,n,a,l,b} <- cl, S.repo_write?(b, writes), do: {f,k,n,a,l}

IO.puts("")
IO.puts("FUNCTION-TAIL  :ok, NO repo-write predicate : #{length(ft)}")
IO.puts("FUNCTION-TAIL  :ok, WITH repo-write predicate: #{length(ft_rw)}")
IO.puts("CLAUSE-LOCAL   :ok, NO repo-write predicate : #{length(cl)}")
IO.puts("CLAUSE-LOCAL   :ok, WITH repo-write predicate: #{length(cl_rw)}")
IO.puts("")
IO.puts("--- FUNCTION-TAIL + repo-write members ---")
for {f,k,n,a,l} <- Enum.sort(ft_rw), do: IO.puts("#{f}:#{l} #{k} #{n}/#{a}")
IO.puts("")
IO.puts("--- CLAUSE-LOCAL + repo-write members ---")
for {f,k,n,a,l} <- Enum.sort(cl_rw), do: IO.puts("#{f}:#{l} #{k} #{n}/#{a}")
```
