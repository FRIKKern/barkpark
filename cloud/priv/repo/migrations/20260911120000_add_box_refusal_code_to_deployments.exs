defmodule BarkparkCloud.Repo.Migrations.AddBoxRefusalCodeToDeployments do
  @moduledoc """
  deploy-reliability (dr-w4-bl-deferral-raw-column-ambiguous): THE BOX'S CODE
  WORD, AS A COLUMN, BECAUSE NO RULE OVER THE PROSE CAN CLOSE THIS ONE.

  ## The hole dr-w4 S6 could not close, and said so

  `Sites.Deploy.refusal_detail/1` renders a typed envelope `{code, message}` as
  `"\#{code} — \#{message}"` and a CODELESS one `{nil, message}` as the bare
  message. So a codeless 409 whose message happens to be byte-for-byte
  `box_at_capacity — the box is at its build capacity` persists to EXACTLY the
  same `failure_reason` bytes as a genuine `code: "box_at_capacity"` refusal.
  S6 closed the readable spoof family (padded / multi-word / punctuated prose no
  longer trims into a code) and wrote in `@code_token`'s comment that the
  byte-identical case is unreachable from that column at all — "moving the
  taxonomy onto a structured field is a design decision above a classifier's pay
  grade". This is that decision.

  ## What this column is NOT

  It is NOT `deferral_cause`. That column (20260807150000) holds the LEDGER
  CLASS — `BOX_AT_CAPACITY_DEFERRED` — which `Sites.Deploy.defer/3` computes by
  calling `DeployLedger.classify/1`, i.e. off the very prose the spoof forges.
  A column-first read of `deferral_cause` reads back the classifier's own frozen
  past output and inherits its mistake. `box_refusal_code` is the box's OWN
  `err["code"]`, extracted from the decoded envelope before any string is built,
  so nothing a `message` can contain reaches it.

  ## NULL vs. "the envelope carried no code" are DIFFERENT FACTS

  A codeless refusal must be distinguishable from a row no code-aware writer
  ever touched, or every pre-existing row would read as "the box named no code"
  and D115 would break: the verbatim 2026-08 corpus in `deploy_ledger_test.exs`
  must keep classifying exactly as it does today. So:

    * NULL             — no code-aware writer wrote this row. Prose fallback.
    * `"(none)"`       — a code-aware writer looked, and the envelope had no
                         `code` key. Read as D7's codeless 409.
    * anything else    — the box's own code word, verbatim.

  `"(none)"` cannot collide with a real code by CONSTRUCTION, not by luck:
  `DeployLedger`'s `@code_token` is `^[a-z][a-z0-9_]*$`, which no parenthesis
  can satisfy, and `deploy_ledger_test.exs` pins that.

  ## Why this ALTER is safe on the live table, and why there is no backfill

  Nullable, no default: a catalog-only `ALTER`, no table rewrite, no per-row
  work — the same argument `20260910180000_add_build_sha256_to_deployments`
  made. Every pre-existing row stays NULL, which is the honest reading: nobody
  recorded a code on those rows, and a backfill out of their own prose would
  re-commit the exact error this column exists to refuse. No index — the reader
  is per-row.
  """

  use Ecto.Migration

  def change do
    alter table(:deployments) do
      add :box_refusal_code, :string
    end
  end
end
