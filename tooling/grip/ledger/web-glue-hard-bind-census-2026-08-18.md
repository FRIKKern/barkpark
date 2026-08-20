# Re-derivation recipe — whole-fence in-body hard-bind census (web glue)

Pinned to `origin/main` = `228090798bf50a3ae2bb15699c04ddf65b2dcdd2`.
Fence: `api/lib/barkpark_web/controllers` (86 files) + `api/lib/barkpark_web/plugs` (49 files).

## 0. The mandated command returns 0 for a MECHANICAL reason — reproduce it first

    git grep -nE '^\s*\{:ok, [a-z_]+\} = ' origin/main -- 'api/lib/barkpark_web/controllers/*'   # => 0 hits
    git grep -nP '^\s*\{:ok, [a-z_]+\} = ' origin/main -- 'api/lib/barkpark_web/controllers/*'   # => hits

git grep's default engine is POSIX ERE, which has no `\s`. Any census regex using
`\s` under `-E` silently matches nothing. Use `-P`, or `[[:space:]]`. A zero from
an `\s`+`-E` grep is a TOOL artifact, never evidence of absence.

## 1. Fence roster

    git grep -c '' origin/main -- 'api/lib/barkpark_web/controllers/*' | wc -l   # 86
    git grep -c '' origin/main -- 'api/lib/barkpark_web/plugs/*'       | wc -l   # 49

## 2. Wide census: every line whose content OPENS with a destructuring LHS then `=`

    git grep -nP '^\s*(\{[^}]*\}|\[[^\]]*\]|%\{[^}]*\}|%[A-Z][A-Za-z0-9_.]*\{[^}]*\}|<<[^>]*>>)\s*=\s*[^=~]' \
      origin/main -- 'api/lib/barkpark_web/controllers/*' 'api/lib/barkpark_web/plugs/*' > /tmp/wide.txt
    wc -l < /tmp/wide.txt          # 149

## 3. Three-way split (the classification that makes the number mean something)

    grep    -E '\->' /tmp/wide.txt | wc -l                      # 88  clause heads  -> SAFE by construction
    grep -v -E '\->' /tmp/wide.txt > /tmp/binds.txt
    grep    '<-' /tmp/binds.txt | wc -l                         # 18  with-clauses  -> SAFE (route to else)
    grep -v '<-' /tmp/binds.txt > /tmp/hard.txt; wc -l < /tmp/hard.txt   # 43  TRUE HARD BINDS

Known false positives still inside the 43 (verify by opening, do not trust the line):
multi-line clause heads whose `when ... ->` sits on the NEXT line
(`bulldocs_ingest_controller.ex:598,606`), and multi-line `defp` parameter
patterns (`cycle_fleet_controller.ex:489`). Net true hard binds: 40.

## 4. Classify a hard bind: read the CALLEE's return clauses, not the call site

    git grep -nP "^\s*def[p]? <name>[ (]" origin/main -- 'api/lib'      # note ${n} braces: zsh reads $n[ (] as a subscript
    git grep -nP '@spec <name>'          origin/main -- 'api/lib/<file>'

A bind is REAL when the callee's own `@spec` or clause set admits a shape the LHS
does not cover. Two decisive shapes found this way:

  * `with` chain with NO `else` — returns the first non-matching value verbatim.
    `cycle_fleet.ex:2585 projection/1` (@spec `{:ok,map}|{:error,atom}`) is hard-bound
    `{:ok, projection} =` at `cycle_fleet_controller.ex:39` and `:234`.
  * A callee whose dep-library `@spec` admits `{:error, term}`:
    `Plug.Conn.chunk/2` (`api/deps/plug/lib/plug/conn.ex:555`).

## 5. Executed proof of the `with`-no-else semantics (no DB, no compile)

    elixir - <<'EOF'
    defmodule M do
      def validate(:bad), do: {:error, :invalid_persisted_correction}
      def reconcile(w), do: (with :ok <- validate(w), do: {:ok, %{ok: true}})
      def projection(w), do: (with {:ok, r} <- reconcile(w), do: {:ok, %{cycle_ledger: r}})
    end
    IO.puts(inspect M.projection(:bad))
    try do {:ok, _} = M.projection(:bad) rescue e in MatchError -> IO.puts("RAISED: #{Exception.message(e)}") end
    EOF

Expect `{:error, :invalid_persisted_correction}` then `RAISED`.

## 6. The idiom-inconsistency test (how the listen finding was isolated)

    git grep -nP 'chunk\(' origin/main -- 'api/lib/barkpark_web/controllers/*' 'api/lib/barkpark_web/plugs/*'

12 sites. 11 are `case chunk(...) do {:ok, c} -> ... ; _ -> conn end`.
`listen_controller.ex:62` is the lone hard bind — and four of its guarded siblings
(`:80 :201 :216 :301`) are in that same file. When a file contains N guarded uses of
a call and ONE unguarded use, the unguarded one is the defect, not the convention.

## 7. What this recipe does NOT prove

`listen_controller.ex:62` is not reachable by `Phoenix.ConnTest`: the test adapter
(`Plug.Adapters.Test.Conn`) always returns `{:ok, conn}` from `chunk/2`, so a
conn-test mutation proof for that line is NOT available. Any claim of a red-without-fix
conn test on that line should be distrusted.
