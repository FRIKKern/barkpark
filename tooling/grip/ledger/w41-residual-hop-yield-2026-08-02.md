# Re-derivation recipe — wave-41 RESIDUAL HOP YIELD (the 22, the 8, the mask)

Derived 2026-08-02 against `origin/main` **20d61d1874a260fec273942dd32d7b4e29d86eb5**, over a clean
`git archive` extraction (NOT the primary checkout). Every integer below is a MEASUREMENT AT A SHA,
re-derived by run; none is transcribed from the wave-41 brief or the survey digest.

## 0. The tree and the baseline census

    D=$(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C "$D"
    (cd "$D"; elixir scripts/pds-elixir-receipt-census.exs) | tail -40
    # rc=0, CENSUS OK, 14 arms PASS / 0 FAIL, wall clock 24814 ms
    # DERIVATION-PARTITION-TOTAL 138 = store_derived 94 + reread_receipt 6 + request_echo 3
    #   + control_flow_gated_literal 2 + literal_only 3 + residual_helper_assembled 22
    #   + residual_onehop_unattributed 8 · RESIDUAL 30

NOTE the cwd trap: `cd "$D" && elixir scripts/...` in a compound Bash call can land in the wrong
directory and print `No file named scripts/pds-elixir-receipt-census.exs` with rc=1. Use a subshell.

## 1. The instrumented copy (three probes, zero behaviour change)

Copy the census to a scratch name and add three env-gated probes. The partition line must stay
byte-identical across all runs — if it moves, the probe changed the measurement and the run is void.

    cp "$D/scripts/pds-elixir-receipt-census.exs" "$D/scripts/dbg.exs"

`derive_def/1` — append to its returned map:

    |> Map.merge(%{dbg_payload: MapSet.to_list(payload_vars), dbg_oks: Map.keys(oks),
                   dbg_head: MapSet.to_list(head),
                   dbg_locals: raw_calls(d) |> Enum.filter(&match?({:local,_,_}, &1)) |> ...,
                   dbg_remotes: ..., dbg_emits: Enum.map(emits, fn {k,_} -> k end)})

`derive_row/3` — three blocks, each behind an env var:

* `PDS_DBG=1` → one `DBG <mod>.<action> class=… payload=… oks=… head=… locals=… remotes=…` line per
  RESIDUAL CLAUSE.
* `PDS_HOP=1` → for every `residual_helper_assembled` clause, `resolve/4` each of its `raw_calls/1`
  targets; where the callee body has `response_emissions/1 != []`, run `derive_def/1` on the CALLEE
  and print `HOP <caller> -> <target> :: hopclass=…`.
* `PDS_MASK=1` → one `MASK` line per ROW whose winning class is DECIDED while some clause of it is
  RESIDUAL.

Runs (each ~25 s, all three printed `CENSUS OK` and the identical partition line):

    (cd "$D"; PDS_DBG=1  elixir scripts/dbg.exs) | grep -c '^DBG'   # 46 residual CLAUSES
    (cd "$D"; PDS_HOP=1  elixir scripts/dbg.exs) | grep  '^HOP' | sort -u   # 29 distinct hop edges
    (cd "$D"; PDS_MASK=1 elixir scripts/dbg.exs) | grep -c '^MASK' # 9 masked ROWS

## 2. The numbers this produced

| quantity | value | how |
|---|---|---|
| residual CLAUSES | 46 | `PDS_DBG` line count |
| … of them `residual_helper_assembled` | 29 | `grep -c 'class=residual_helper_assembled'` |
| … of them `residual_onehop_unattributed` | 17 | `grep -c 'class=residual_onehop_unattributed'` |
| … of them `residual_undecided` | 0 | `grep -c 'class=residual_undecided'` |
| MASKED rows (decided row, residual clause) | 9 | `PDS_MASK` line count |
| residual-TOUCHING rows | 39 | 30 printed + 9 masked |
| **one-hop join yield over the 22** | **15** | `PDS_HOP` edges, min-by `@derivation_order` per row |

The 15: AppToken.create + AppToken.delete + Chat.archive + Chat.unarchive + Webauthn.login
(→ store_derived, 5) · CycleFleet.promote/quarantine/rollback (→ reread_receipt via `projection`, 3)
· Auth.register + TicketKeys.pause×2 + TicketKeys.unpause×2 (→ request_echo, 5) ·
SelfUpdate.rollback + SiteDeploy.trigger (→ literal_only, 2).

The 7 that do NOT convert at one hop: Auth.login, Auth.magic_login, Auth.mfa_enroll (all three
reach `SessionIssuer.issue/3` only THROUGH the one-line private wrapper `issue_session/3`, so they
need TWO hops), Mutate.mutate ×2 (only hop with an emission is `respond_with_error/2`),
ScimUsers.replace (hops into `update/2`, itself a member of the 8), Webauthn.step_up_challenge
(hops into `login_challenge/2`, itself a member of the 8).

## 3. The three terminals the assignment named

    (cd "$D"; head -60 api/lib/barkpark_web/session_issuer.ex)
    # issue/3 emits `json(login_body(token, user))` IN ITS OWN def — one hop suffices, and
    # `{:ok, token} = Accounts.create_user_session_token(...)` is an `=`-bound ok pattern that
    # ok_walk/1 DOES model. Confirmed by the HOP line: hopclass=store_derived
    # producer=create_user_session_token.

    grep -n 'defp with_scope' api/lib/barkpark_web/controllers/cycle_fleet_controller.ex   # 372
    # with_scope/4 is NOT the response path. The success receipt is
    # `respond_correction_mutation(conn, scope, CycleFleet.<verb>_correction(...))` written
    # INSIDE the `fn scope -> … end` the action passes — raw_calls/1 prewalks closures, so the
    # hop target is found. It resolves to reread_receipt (`CycleFleet.projection/1`), NOT
    # store_derived: the write's own return is matched as `{:ok, _event}` and DISCARDED.

    # The three unopened members of the 8:
    #   ChatController.create   — payload [:id], `id = Ecto.UUID.generate()`; receipt is
    #                             `json(full_session_json(StudioChat.get_session(id), []))` → a RE-READ.
    #   ScimGroupsController.update — payload [:group, :org, :unmatched];
    #                             `group = Scim.get_org_group(org, id) || group` → a RE-READ.
    #   WorkspaceController.import — payload [:binary, :other]; BOTH emissions the pass reads are
    #                             ERROR branches (403 bundle_import_disabled, 422 invalid_mode).
    #                             The success receipt is behind the CAPTURE `&clean_import/3`
    #                             handed to `with_spilled_body/2` — not a call the hop can follow.

## 4. The cheapest fix is neither the hop nor a provenance pass

`ok_payload/1` matches only TWO-tuples (`defp ok_payload({a, b})`). A three-element ok tuple quotes
as `{:{}, meta, [...]}` and is invisible to it:

    elixir -e 'IO.inspect(Code.string_to_quoted!("{:ok, a, b}"))'   # {:{}, [line: 1], [:ok, {:a,…}, {:b,…}]}

`MediaController.put_blob` matches `{:ok, written, receipt} <- Media.put_blob(…)` and renders
`written`, `receipt` and `byte_size(body)` — a genuine store-derived receipt sitting in the 8 purely
on tuple ARITY. Textual reach of the shape:

    grep -rn '{:ok, [a-z_][a-zA-Z0-9_]*, ' "$D/api/lib/barkpark_web/controllers/" | wc -l   # 31 (14 files)

## 5. Falsifiers

* Re-run any probe; if the `DERIVATION-PARTITION-TOTAL` line differs from §0, the instrumentation
  is not behaviour-neutral and every number here is void.
* If `PDS_MASK` prints anything other than 9, the "residual-touching = 39" arithmetic is wrong.
* If a `HOP` line's `hopclass` for CycleFleet stops reading `reread_receipt producer=projection`,
  `respond_correction_mutation/3` changed and the yield-15 tally must be recomputed.
