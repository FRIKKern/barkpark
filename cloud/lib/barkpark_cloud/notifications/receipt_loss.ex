defmodule BarkparkCloud.Notifications.ReceiptLoss do
  @moduledoc """
  THE RECEIPT THAT COULD NOT BE WRITTEN — one funnel, and one register of every
  branch that can lose one (`cch-w32-bl-receipt-loss-branches-have-no-trace`).

  ## The class, and why it is NOT a withhold

  A **withhold** is a notification the system decided not to send
  (`Notifications.Withhold`). This is the opposite shape: the notification WENT
  OUT — the mail relay took it, or the chat provider answered — and the RECEIPT
  failed to write. Routing it through `Withhold` would stamp a `suppressed` row
  asserting the send never happened, which is the reverse of what occurred.

  What that costs when nothing is done about it, measured on the two branches
  this module now serves: the delivery log silently UNDER-REPORTS successful
  sends, and the failure of the log to log is invisible on the log. A
  `Logger.error` line is the fallback that nobody reads, and there is no surface
  a person can reach that says a send is missing from their own delivery list.

  ## The adjudication, per site

  `sites/0` is the closed register. Every Delivery-write site in `cloud/lib` is
  in it with one of two verdicts, and `receipt_loss_census_test.exs` reds if a
  THIRD receipt-write site appears without one:

    * `:traced` — the loss gets a durable trace a person can reach.
    * `:consented` — a trace is impossible, and the entry says WHY in a sentence
      that names the code rather than gesturing at it.

  ## The trace: A REDUCED RECEIPT, not a new surface

  `Repo.insert/1` answers `{:error, changeset}` for a row the database REFUSED —
  a validation or a constraint. A dropped connection raises instead. So the row
  itself is what was rejected, and a NARROWER row built from the same measured
  facts is not a retry of the same write: it is the receipt with the parts that
  can themselves be the refusal taken off.

  `rescue_receipt/3` walks that ladder, most complete first:

    1. `:without_content` — drops `content_sha256` / `content_subject` /
       `content_counts`. These are the only columns carrying RENDERED material
       and the only ones under a byte ceiling and a closed key vocabulary
       (`Delivery.content_retention_ruling/0`), so they are the likeliest refusal
       and the cheapest to lose.
    2. `:identifying_only` — keeps `recipient` / `event` / `channel` / `kind` /
       `status` / `attempts` and nothing else. Every dropped column is either a
       REFERENCE that can fail its constraint (`team_id`, when the team went away
       mid-send) or a CLAMPED string (`last_error`, `carrier`). What is left is
       the minimum `Delivery.changeset/2` will accept and the facts the receipt
       exists for: this address was sent this event, with this outcome.

  A stage whose attributes equal the ones already refused is SKIPPED — the
  database is never asked twice for the same write.

  ## What a reduced row says, and what it must not

  Every field on it was MEASURED. Nothing is manufactured to fill a gap: a
  dropped column lands NULL, and `Delivery` already renders each of those
  absences as a sentence rather than a blank (`content_proof_meaning/1`,
  `content_block_meaning/2`). A reduced row is thinner than the receipt that was
  refused, and it is not a claim about anything it does not carry.

  It is also NOT a new status word. `status` stays the transport verdict the send
  actually produced, because that is what was measured; minting a fifth word
  would make every reader that knows four render a blank.

  ## When even the reduced row cannot be written

  Then the loss is REAL and this module says so out loud rather than quietly: a
  `Logger.error` naming the site and the refusal, plus
  `telemetry_event/0` at `:lost`, so an operator has a countable signal instead
  of a line in a stream. That residue is named, not hidden — a recipient that is
  itself `nil` leaves nothing true to write down, and charter D362 forbids
  inventing an address to carry a row.

  ## It can never break the send

  Every path is wrapped: a raise inside a receipt rescue answers `:lost`. The
  notification already went out; nothing here is allowed to take the caller down
  with it.
  """

  require Logger

  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.Repo

  @telemetry_event [:barkpark_cloud, :notifications, :receipt_loss]

  # The facts a receipt exists to carry. `recipient` and `event` are what
  # `Delivery.changeset/2` requires; the other four are closed vocabularies with
  # schema defaults, so a reduced row is representable whenever the send itself
  # was.
  @identifying_fields [:recipient, :event, :channel, :kind, :status, :attempts]

  # dr-w29 / dr-w34 columns: the rendered material, and the only clamps that
  # depend on what the message SAID rather than on what the send DID.
  @content_fields [:content_sha256, :content_subject, :content_counts]

  # THE CLOSED REGISTER. `anchor` must match live code in the named file — an
  # entry whose code is gone reds the census rather than certifying an absence
  # that has moved (the wave-51 lesson: an excused name is worse than a bare one).
  @sites [
    %{
      site: :record_delivery,
      module: BarkparkCloud.Notifications,
      file: "barkpark_cloud/notifications.ex",
      adjudication: :traced,
      writers: [:record_delivery],
      anchor: ~r/defp record_delivery\(/,
      why:
        "The email send already returned. The receipt is reduced and re-written, " <>
          "so the address still appears in its own delivery list with the outcome " <>
          "the transport produced."
    },
    %{
      site: :log_chat_delivery,
      module: BarkparkCloud.Notifications,
      file: "barkpark_cloud/notifications.ex",
      adjudication: :traced,
      writers: [:log_chat_delivery],
      anchor: ~r/defp log_chat_delivery\(/,
      why:
        "The chat POST already returned. Same ladder as record_delivery/7 — the " <>
          "channel row is reduced rather than lost."
    },
    %{
      site: :insert_suppressed,
      module: BarkparkCloud.Notifications.Withhold,
      file: "barkpark_cloud/notifications/withhold.ex",
      adjudication: :consented,
      # TWO enclosing functions, one write: `publishable?/1` builds and
      # validates the changeset, `insert_suppressed/1` issues the statement.
      writers: [:insert_suppressed, :publishable?],
      anchor: ~r/defp publishable\?\(attrs\)/,
      why:
        "NOT A RECEIPT and not reducible. A suppressed row's `last_error` IS its " <>
          "content — the sentence disclosing the decision — so the identifying-only " <>
          "row this module would write is a withhold with no disclosure, which is " <>
          "the defect Withhold exists to kill. It refuses the row before the insert " <>
          "and logs the refusal instead."
    },
    %{
      site: :receipt_rescue,
      module: BarkparkCloud.Notifications.ReceiptLoss,
      file: "barkpark_cloud/notifications/receipt_loss.ex",
      adjudication: :consented,
      # This module's OWN write. It is registered rather than excused by the
      # census, because the funnel is a delivery writer like any other.
      writers: [:walk_ladder],
      anchor: ~r/defp walk_ladder\(site, attrs, \[/,
      why:
        "THE LAST RUNG. A reduced receipt that is itself refused has nothing " <>
          "narrower left that is true — every remaining column is required by " <>
          "`Delivery.changeset/2` — so there is no further trace to write. The " <>
          "residue is named out loud instead: a Logger.error and a `:lost` " <>
          "telemetry count, which is the honest end of the ladder rather than a " <>
          "fourth rung that invents a value."
    }
  ]

  @doc "The telemetry event every receipt loss emits. Measurement `%{count: 1}`."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc "The closed adjudication register — one entry per Delivery-write site in cloud/lib."
  @spec sites() :: [map()]
  def sites, do: @sites

  @doc "The adjudication entry for one site name, or `nil`."
  @spec adjudication(atom()) :: map() | nil
  def adjudication(site), do: Enum.find(@sites, &(&1.site == site))

  @doc "The columns a reduced receipt keeps when it keeps nothing else."
  @spec identifying_fields() :: [atom()]
  def identifying_fields, do: @identifying_fields

  @doc """
  Write the narrowest TRUE receipt still available after `attrs` was refused.

  Returns `{:reduced, delivery}` when a row landed, `:lost` when none could.
  Never raises: the send it is a receipt for already happened.
  """
  @spec rescue_receipt(atom(), map(), Ecto.Changeset.t()) :: {:reduced, Delivery.t()} | :lost
  def rescue_receipt(site, attrs, %Ecto.Changeset{} = refused) when is_map(attrs) do
    Logger.error(
      "Notifications: #{site} could not record a delivery receipt: " <>
        "#{inspect(refused.errors)} — reducing"
    )

    walk_ladder(site, attrs, ladder(attrs))
  rescue
    error ->
      Logger.error(
        "Notifications: #{site} receipt rescue crashed: #{Exception.message(error)} — " <>
          "the send happened and has NO receipt"
      )

      emit(site, :lost, :crashed)
      :lost
  end

  # Most complete first, and never the map that was already refused.
  defp ladder(attrs) do
    [
      {:without_content, Map.drop(attrs, @content_fields)},
      {:identifying_only, Map.take(attrs, @identifying_fields)}
    ]
    |> Enum.reject(fn {_stage, reduced} -> reduced == attrs end)
    |> Enum.uniq_by(fn {_stage, reduced} -> reduced end)
  end

  defp walk_ladder(site, _attrs, []) do
    Logger.error(
      "Notifications: #{site} has NO receipt for a send that happened — nothing " <>
        "narrower than the refused row is true"
    )

    emit(site, :lost, :none_narrower)
    :lost
  end

  defp walk_ladder(site, attrs, [{stage, reduced} | rest]) do
    %Delivery{}
    |> Delivery.changeset(reduced)
    |> Repo.insert()
    |> case do
      {:ok, delivery} ->
        Logger.warning(
          "Notifications: #{site} wrote a REDUCED receipt (#{stage}) id=#{delivery.id} — " <>
            "the send is in the delivery log with less detail than it was measured with"
        )

        emit(site, :reduced, stage)
        {:reduced, delivery}

      {:error, _changeset} ->
        walk_ladder(site, attrs, rest)
    end
  end

  defp emit(site, outcome, stage) do
    :telemetry.execute(@telemetry_event, %{count: 1}, %{
      site: site,
      outcome: outcome,
      stage: stage
    })
  end
end
