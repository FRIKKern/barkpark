# tenancy-auth uuid-equivalence, proven on the RUNNING system (L1)

Wave: tenancy-auth-totality-wave-2026-08-19 · assignment: uuid-equivalence-live-db
Tree: primary checkout, `api/lib/barkpark/tenancy/` and `api/lib/barkpark/repo.ex`
byte-identical to `origin/main` (bf499f54b6) — verified with
`git diff --quiet origin/main -- api/lib/barkpark/tenancy/`.

## Re-derivation

```
cd /Volumes/SATECHI/github/barkpark/api && MIX_ENV=test mix run <<'X'
alias Barkpark.{Repo, Tenancy}
alias Barkpark.Tenancy.Auth
Ecto.Adapters.SQL.Sandbox.checkout(Repo)
{:ok, ws} = Tenancy.create_workspace(%{name: "eqv", slug: "eqv-#{System.unique_integer([:positive])}"})
pid = Ecto.UUID.generate()
{:ok, m} = Auth.create_membership(ws.id, pid, "admin")
IO.puts("canonical  SAME_ROW=#{Auth.membership(pid, ws.id).id == m.id}")
IO.puts("uppercase  SAME_ROW=#{Auth.membership(pid, String.upcase(ws.id)).id == m.id}")
IO.puts("normalised SAME_ROW=#{Auth.membership(pid, Repo.uuid_or_nil(String.upcase(ws.id))).id == m.id}")
IO.puts("principal-upcase SAME_ROW=#{Auth.membership(String.upcase(pid), ws.id).id == m.id}")
raw = Ecto.UUID.dump!(ws.id)
IO.inspect(Repo.uuid_or_nil(raw) == ws.id, label: "raw16 normalises to ws.id")
IO.inspect(Auth.membership(pid, Repo.uuid_or_nil(raw)).id == m.id, label: "AFTER-SEAM raw16 SAME_ROW")
IO.inspect(Auth.membership(pid, Repo.uuid_or_nil("warehouse worker")), label: "AFTER-SEAM 16byte-string")
IO.inspect(Ecto.UUID.cast("warehouse worker"), label: "16byte-cast")
X
```

Crash matrix on the SAME code (each wrapped in try/rescue):
`membership(pid, "warehouse worker")`, `(pid, <<0..15>>)`, `(pid, "")`, `(pid, "zzz")`,
`(pid, "  <uuid>  ")` → `Ecto.Query.CastError` at auth.ex:145.
`(pid, nil)`, `(nil, ws.id)`, `(%ApiToken{id: nil}, ws.id)` → `FunctionClauseError`.
`role_permits?("admin", "", :admin)` → `true` (no DB read).
`role_permits?("nonbuiltin", "", :admin)` → `Ecto.Query.CastError` at auth.ex:266 (db_actions).

## Verdicts

1. UPPERCASE ALREADY RESOLVES TODAY, unnormalised — same membership row id.
   Normalisation is a NO-OP for that shape; it cannot deny a legitimate admin.
   Holds for the principal id position too.
2. `Repo.uuid_or_nil` contains NO `String.trim` (8-line body, `Ecto.UUID.cast` only);
   `grep -rn "String.trim" api/lib/barkpark/tenancy/` hits only janitor.ex:299 and
   archive.ex:335 — neither on the auth path. A whitespace-padded id must keep
   normalising to `nil` (DENY). Adding trim would WIDEN.
3. The 16-byte edge is ONE class, not two: `Ecto.UUID.cast/1` accepts ANY 16-byte
   binary as raw UUID bytes. `"warehouse worker"` → `{:ok, "77617265-686f-7573-6520-776f726b6572"}`.
   Today every 16-byte non-canonical binary CRASHES (`dump` rejects it). After the
   seam it reaches the query and DENIES (no row with the synthetic id).
4. WIDENING TO DECLARE: `Ecto.UUID.dump!(ws.id)` (the real 16 raw bytes) crashes today
   and RESOLVES the real membership after the seam. No privilege is gained — producing
   those bytes requires already holding the UUID — but the moduledoc must say
   "malformed ids DENY", never "malformed ids never reach the query".
5. Exception module: `Ecto.Query.CastError`, never `Ecto.CastError`. `Repo.uuid_or_nil`'s
   own docstring names the wrong module and should be corrected.
