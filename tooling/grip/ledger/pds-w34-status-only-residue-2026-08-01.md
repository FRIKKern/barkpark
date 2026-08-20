# PDS w34 — status-only residue, re-derived (2026-08-01)

Verifier lane `v11-status-only-residue-rederived`. Tree: **origin/main = 97a581f6de6961124ba22fe14aad291cc32d3e7b**.
Elixir 1.19.5 / OTP 28. Two facts that were DEMOTED-NO-RERUN now have a command.

The classifier source is checked in beside this row as
`tooling/grip/ledger/pds-w34-status-only-residue-classifier.exs.txt`.
**Decide: move it to `scripts/pds-status-only-residue.exs`** (verifier fence forbids
writing outside `tooling/grip/ledger/`; the file is byte-ready, no edits needed).

## Re-derivation

```sh
D=$(mktemp -d)
git -C /path/to/barkpark archive origin/main api/lib | tar -x -C "$D"
cp tooling/grip/ledger/pds-w34-status-only-residue-classifier.exs.txt "$D/pds.exs"
cd "$D" && elixir pds.exs api/lib
```

Expected on 97a581f6d (all five SELFTEST arms PASS):

```
json/2 call sites (AST, pipes normalized): 460
  of which line textually matches 'json(conn,': 192
STATUS LENS  explicit_2xx: 66  explicit_non2xx: 184  implicit_200: 210
SUBSUMPTION VERDICT: HOLDS (every put_status(2xx) terminates in json/2)
literal-only AND 2xx AND write-reachable: 10
A3 request-echo AND 2xx AND write-reachable: 6
send_resp(conn, 2xx): 3
STATUS-ONLY RESIDUE: 19
```

## Mutation proof (the lens can fail)

Rewrite `api/lib/barkpark_web/controllers/schema_controller.ex:61-62`
`with {:ok, _} <- ... json(conn, %{deleted: name})` → `with {:ok, row} <- ... json(conn, %{deleted: row.name})`;
the A3 arm drops **6 → 5** and that exact row disappears. Restore afterwards.

## Lens corrections carried

| Quoted fact | Lens it was measured at | Corrected |
|---|---|---|
| `218 json(conn, …)` | `git grep 'json(conn,'` — no left token boundary | 26 are `error_json(`/`respond_json(`/`halt_json(`/`parse_error_json(`; 268 real piped `json/2` sites invisible. Real population **460** |
| `66 put_status(2xx) ⊂ the 218` | textual | **0 of 66** carry `json(conn,` on their line. Subsumption is true only at the AST lens |
| `distinct sites 221` | 218 + 3 | **463** (460 json/2 + 3 send_resp) |
| `honest residue ~16 (7%)` | 16/221 | 16 json sites reproduce; **19** with send_resp; **19/463 = 4.1%** |
| `~14 mutation sites` via def NAME | name lens | write-reachability lens moves 7 name-READ sites into write-reachable |
| `59/68/77/14` | undefined | bucket DEFINITIONS are unrecoverable; superseded by status × write-reachability cross (printed) |
