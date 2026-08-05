defmodule BarkparkCloud.Repo.Migrations.BackfillLegacyLastError do
  use Ecto.Migration

  alias BarkparkCloud.Notifications.DeliveryReason

  @moduledoc """
  Wave 32 S5 (cloud-console-hardening). Wave 31 S1 (`bd6cf848f`) closed the WRITE
  SEAM — `record_delivery/5` now stores `DeliveryReason.summarize/1`, a constant
  sentence — and it is deployed. But a write-seam fix cannot touch rows already on
  disk, and `Web.Router.delivery_json/1` serves `last_error` VERBATIM to every team
  admin (`app.js` renders `esc(d.last_error)` on the delivery row).

  MEASURED ON PRODUCTION, READ-ONLY, 2026-08-05: `notification_deliveries` holds
  1796 rows, exactly FOUR with a non-null `last_error`, and ALL FOUR are raw
  pre-`bd6cf848f` transport terms — none matches the closed vocabulary. All four
  are one team, `channel = "email"`, and every one is the gen_smtp shape
  `{:retries_exceeded, {:network_failure, ~c"<host>", {:error, :econnrefused}}}`
  whose embedded host is an IPv4 address. That host is the team's SMTP relay:
  `Notifications.settings_view/1` masks it to `"********"` for every reader
  INCLUDING the owner (`smtp_host_encrypted`, `redact: true`, Vault-sealed at
  rest). The system decided the relay address is a secret and is publishing it
  anyway, and it CANNOT age out: nothing in `cloud/lib` or `cloud/priv/repo`
  deletes, prunes or reaps `notification_deliveries`. "Wait" is not an option, so
  this is the one UPDATE that ends it.

  ## The predicate is an ALLOWLIST, deliberately

  A denylist (`last_error LIKE '{:%'`) would only catch the shape we happened to
  find in prod today; an older build that wrote a differently-shaped raw term
  would sail through. So the rule is inverted: anything that is NOT provably one
  of `DeliveryReason`'s constant sentences is legacy and gets rewritten to
  `label(:unknown)`. The constants are DERIVED from `DeliveryReason.classes/0`
  at migration time rather than re-typed here, so a vocabulary change cannot
  leave this file quietly disagreeing with the module it guards. The one label
  that is not constant — `{:http_status, code}`, whose integer interpolates — is
  matched by a LIKE pattern derived from `label/1` itself with a probe integer.

  ## Scale

  Four rows. A plain in-transaction `UPDATE` finishes instantly; there is no
  index, no `CREATE INDEX CONCURRENTLY` (charter D366 records that shape's proved
  fail-green trap) and no per-row loop, and the slow-data-migration precedent
  does not apply at n=4. `cloud/Dockerfile:121` runs `Release.migrate()` BEFORE
  `barkpark_cloud start`, so the slot does not listen until this finishes, and
  `deploy/cp-deploy.sh:120` health-gates ~180-400s before `exit 14` — an UPDATE
  over 4 rows is nowhere near that budget.
  """

  # Any integer works; it exists only to locate the interpolation point in the
  # one non-constant label so the LIKE pattern can be DERIVED, not typed.
  @http_probe 424_242

  def up do
    {sql, params} = backfill_statement()
    %Postgrex.Result{num_rows: rewritten} = repo().query!(sql, params)

    log_result(rewritten)
  end

  # NOT REVERSIBLE, AND SAYING SO OUT LOUD. This migration overwrites the raw
  # transport term with a constant sentence; the original bytes exist nowhere in
  # this table afterwards, so no `down/0` can restore them (the raw terms remain
  # in the server log, which is where operator debugging belongs and where wave 31
  # S1 deliberately left them). `down/0` therefore does nothing — but it announces
  # that, because a down that is silently empty reads like "nothing happened."
  # It does not raise: this migration changes no schema, so a rollback across it
  # is meaningless rather than dangerous, and raising would block the rollback of
  # unrelated later migrations.
  def down do
    IO.puts("""
    BackfillLegacyLastError: NOT REVERSIBLE — the pre-classification transport
    terms were overwritten and are not recoverable from notification_deliveries.
    The raw terms remain in the server log. down/0 is a deliberate no-op.
    """)

    :ok
  end

  @doc """
  The single UPDATE, as `{sql, params}` — public so the guard test can exercise
  the EXACT predicate that ships rather than a paraphrase of it.

  Params are positional: `$1` is the replacement label, `$2..$N` the constant
  vocabulary, and the last one the derived HTTP-status LIKE pattern.
  """
  @spec backfill_statement() :: {String.t(), [String.t()]}
  def backfill_statement do
    constants = constant_labels()
    placeholders = Enum.map_join(2..(length(constants) + 1), ", ", &"$#{&1}")
    like_placeholder = "$#{length(constants) + 2}"

    sql = """
    UPDATE notification_deliveries
       SET last_error = $1
     WHERE last_error IS NOT NULL
       AND last_error NOT IN (#{placeholders})
       AND last_error NOT LIKE #{like_placeholder} ESCAPE '\\'
    """

    {sql, [DeliveryReason.label(:unknown)] ++ constants ++ [http_status_like_pattern()]}
  end

  @doc """
  Every label `DeliveryReason` can emit that is a CONSTANT sentence — derived from
  `classes/0`, never re-typed.
  """
  @spec constant_labels() :: [String.t()]
  def constant_labels, do: Enum.map(DeliveryReason.classes(), &DeliveryReason.label/1)

  @doc """
  The LIKE pattern for the one label whose text varies —
  `label({:http_status, code})` — derived by interpolating a probe integer and
  replacing it with `%`, so the pattern cannot drift from the sentence.
  """
  @spec http_status_like_pattern() :: String.t()
  def http_status_like_pattern do
    [prefix, suffix] =
      DeliveryReason.label({:http_status, @http_probe})
      |> String.split(Integer.to_string(@http_probe), parts: 2)

    escape_like(prefix) <> "%" <> escape_like(suffix)
  end

  defp escape_like(fragment) do
    fragment
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp log_result(rewritten) do
    IO.puts(
      "BackfillLegacyLastError: rewrote #{rewritten} legacy last_error value(s) " <>
        "to the closed-vocabulary sentence."
    )
  end
end
