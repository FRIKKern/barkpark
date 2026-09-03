defmodule BarkparkCloud.Notifications.Withhold do
  @moduledoc """
  The one funnel through which a WITHHELD notification becomes a VISIBLE row.

  ## The definition this module is built on (wave 32, charter D363)

  A **silent withhold** is a branch where the system was positioned to send a
  notification, does not send it, AND writes no `Delivery` row — i.e. it is
  invisible on the only surface built to answer *"was I notified?"*. The lens
  matters: a user's own disabled toggle is NOT a withhold (counting it would make
  "withhold" mean "any switch that is off"); a decision the system made FOR the
  user, without telling them, is.

  Every branch that makes such a decision routes here, so the console grows one
  honest vocabulary instead of one silence per branch.

  ## The grain: ONE ROW PER MEMBER, with that member's own address

  A withheld alert is withheld from PEOPLE. A single team-level marker row would
  be unreadable by the member it concerns, because the delivery log is read
  per-recipient — so `record/4` fans to `Accounts.list_team_member_emails/1` and
  writes one `status: "suppressed"` row per member, `recipient` being that
  member's real address. Never a synthetic recipient: a fabricated address is a
  row that says a person was involved who was not.

  ## The consented zero-recipient cases, named

  Two withhold sites have NO recipient by construction, and `Delivery` requires
  one (`validate_required([:recipient, :event])`):

    * **a team with zero member emails** — there is nobody the alert was withheld
      FROM, so there is nobody to show a row to; and
    * **the fleet digest with no platform admins configured** — the same shape one
      level up, an operator-scoped send with an empty operator list.

  Both are CONSENTED withholds under the definition above: they are not the system
  quietly deciding against a person, they are the absence of a person. `record/4`
  therefore returns `0` for them rather than raising or inventing a recipient — a
  count, so a caller can still log or assert on it.

  Until `dr-w18-s3-fu` that promise was only HALF kept, and the missing half made
  the module unusable for the case it names. The zero-member team reaches it
  honestly — it has a `team_id`, so it takes the recording clause and the fan-out
  over an empty member list returns `0` on its own. The fleet digest does NOT: it
  has no `team_id` by construction, so every call from it fell through to the
  catch-all and logged `refused an unrecordable withhold` — a CONSENTED absence
  reported as an operator bug, once per day, forever. A caller cannot be asked to
  route through a funnel that answers it with a false error, so
  `deliver_fleet_digest/1` did not call this module at all and the branch stayed
  outside the shared vocabulary.

  `@consented_reasons` closes that: a reason on that list is answered with a
  quiet, honest `0` whatever `team_id` is — no row, no error line. Quiet HERE is
  not quiet ANYWHERE: the count goes back to the caller, which accounts it on the
  rail that already speaks (`fleet_digest phase=settled … withheld=0` at WARNING).
  The loudness lives where an operator reads it, not on a line that names a bug
  that is not one.

  ## The reason lands in `last_error`

  `Delivery.changeset/2` clamps `last_error` to the union of `DeliveryReason`'s
  FAILURE vocabulary and `labels/0` below. The two sets are disjoint on purpose:
  every `DeliveryReason` sentence describes an attempted-and-failed send, and none
  of them can honestly describe a send that never left.
  """

  require Logger

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.Repo

  @status "suppressed"

  # THE CLOSED VOCABULARY. `record/4` guards on `reason in @reasons` and the
  # catch-all clause writes NO row — so a caller that invents a reason without
  # adding it here is a silent withhold reintroduced INSIDE the fix. Two guards
  # stand against that: the catch-all below LOGS instead of failing quietly, and
  # `withhold_test.exs` derives every reason atom passed to `Withhold.record/4`
  # from `notifications.ex`'s AST and asserts it is a member of this list.
  # THE CONSENTED SUBSET — reasons whose ZERO is correct by construction, not a
  # refusal. There is no recipient to name, so there is no row to write and
  # nothing was decided against anybody; the catch-all's error line would be
  # false. These are still REASONS, not an absence of one: they pass the
  # AST-derived `@reasons` pin in `withhold_test.exs` like every other call, so a
  # caller cannot reach the quiet path by inventing a name.
  @consented_reasons [:no_recipient_by_construction]

  @reasons [:reap_alert_cap, :dispatch_crashed, :chat_enqueue_failed, :chat_channel_gone] ++
             @consented_reasons

  @type reason ::
          :reap_alert_cap
          | :dispatch_crashed
          | :chat_enqueue_failed
          | :chat_channel_gone
          | :no_recipient_by_construction

  @doc """
  The `Delivery.status` a withheld notification is recorded under. One word, no
  migration — see `Delivery`'s moduledoc.
  """
  @spec status() :: String.t()
  def status, do: @status

  @doc """
  The closed WITHHOLD vocabulary — the reasons this system is willing to publish
  for a notification it decided not to send.
  """
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc """
  The CONSENTED subset of `reasons/0` — the withholds whose `0` is the honest
  answer because there is no recipient by construction. `record/4` returns `0`
  for these without the unrecordable-withhold error line.
  """
  @spec consented_reasons() :: [reason()]
  def consented_reasons, do: @consented_reasons

  @doc """
  The person-facing sentence for a withhold reason. Every arm is a CONSTANT:
  nothing from the triggering event interpolates, so this text is safe to publish
  on a row a team admin reads.
  """
  @spec label(reason()) :: String.t()
  def label(:reap_alert_cap),
    do:
      "Withheld: too many deployment alerts in one sweep, so this one was not sent. " <>
        "The deployment itself is failed in the console."

  def label(:dispatch_crashed),
    do:
      "Withheld: the notification system failed while preparing this alert, so it " <>
        "was not sent. The event that triggered it still happened."

  def label(:chat_enqueue_failed),
    do:
      "Withheld: this alert could not be queued for its chat channel, so it was " <>
        "never sent there. Email delivery for the same event is listed separately."

  def label(:chat_channel_gone),
    do:
      "Withheld: the chat channel this alert was routed to was disconnected before " <>
        "it could be sent, so it was not delivered there."

  def label(:no_recipient_by_construction),
    do:
      "Withheld: there was no one to send this to — the audience for this " <>
        "notification is empty, so nothing was sent and no one was skipped."

  @doc """
  Every withhold sentence, for the `last_error` clamp in `Delivery.changeset/2`.
  """
  @spec labels() :: [String.t()]
  def labels, do: Enum.map(@reasons, &label/1)

  @doc """
  Record a withheld notification for one team: one `suppressed` `Delivery` row per
  team member, with that member's own address as `recipient`.

  `team_id` arrives ALREADY RESOLVED — the caller owns whatever hop (site → team,
  barkpark → team) its own domain knows about; this module does not reach into
  another context's resolver.

  Options: `:channel` (default `"email"`) and `:kind` (default `"alert"`), both
  from `Delivery`'s own closed vocabularies.

  Returns the NUMBER of rows written. Zero is a legitimate answer (see the
  consented zero-recipient cases in the moduledoc); it never raises, because every
  caller is a notification side path that must not be able to break its trigger.
  """
  @spec record(binary() | nil, String.t(), reason(), keyword()) :: non_neg_integer()
  def record(team_id, event, reason, opts \\ [])

  # THE CONSENTED ZERO — first, so it wins for ANY `team_id`, present or nil.
  # `Delivery.changeset/2` runs `validate_required([:recipient, :event])` and
  # charter D362 refuses a synthetic address, so a reason on this list can never
  # produce a row no matter who calls it; ordering the clause after the recording
  # one would let a consented reason arriving WITH a team_id fan out `suppressed`
  # rows to people the notification was never withheld from.
  #
  # It returns `0` and says nothing. That is not the quiet this module exists to
  # kill: the count is the record, and it goes to a caller that is required to
  # account it out loud. The catch-all below stays loud for everything else.
  def record(_team_id, event, reason, _opts)
      when is_binary(event) and reason in @consented_reasons do
    0
  end

  def record(team_id, event, reason, opts)
      when is_binary(team_id) and is_binary(event) and reason in @reasons do
    channel = Keyword.get(opts, :channel, "email")
    kind = Keyword.get(opts, :kind, "alert")
    last_error = label(reason)

    # ONE member-email query per call, and ONE insert for the whole fan-out. The
    # grain is untouched: `list_team_member_emails/1` still decides how many rows
    # there are, and there is still exactly one row per member with that member's
    # own address.
    team_id
    |> Accounts.list_team_member_emails()
    |> Enum.map(fn recipient ->
      %{
        team_id: team_id,
        recipient: recipient,
        event: event,
        channel: channel,
        kind: kind,
        status: @status,
        # Nothing was attempted, and the count must not read as one try that
        # failed — `attempts: 0` is the honest number.
        attempts: 0,
        last_error: last_error
      }
    end)
    |> insert_suppressed()
  rescue
    # A withhold trace must never be able to break the branch it is tracing.
    error ->
      Logger.error("Notifications.Withhold.record/4 crashed: #{Exception.message(error)}")
      0
  end

  # THE UNRECORDABLE WITHHOLD — loud, never quiet. Zero rows is the honest
  # outcome for a caller with no team, no event name, or a reason outside
  # `@reasons`, but a QUIET zero is this epic's own defect rebuilt inside its
  # own fix: a withhold that writes nothing and says nothing. So this arm names
  # what it refused and why, on the operator log, every time.
  def record(team_id, event, reason, _opts) do
    Logger.error(
      "Notifications.Withhold: refused an unrecordable withhold and wrote NO row — " <>
        "team_id=#{inspect(team_id)} event=#{inspect(event)} reason=#{inspect(reason)}. " <>
        "A reason outside #{inspect(@reasons)} needs adding there and to label/1."
    )

    0
  end

  # The columns `record/4` fills, and the only ones a caller may hand this
  # function. Taking a fixed set (rather than the caller's whole map) keeps a
  # stray key from reaching `insert_all`, which would raise on an unknown field.
  @insertable_fields [
    :team_id,
    :recipient,
    :event,
    :channel,
    :kind,
    :status,
    :attempts,
    :last_error,
    :http_status
  ]

  @doc """
  Write a batch of `suppressed` rows in ONE statement, VALIDATING each through
  `Delivery.changeset/2` first. Returns the number of rows written.

  This is the production write path `record/4` funnels into, made public so the
  batched shape is testable at its own grain rather than only through a caller.

  ## The clamp is not bypassed, which is the whole reason this is not a bare
  ## `Repo.insert_all/2`

  `Delivery.changeset/2` clamps `last_error` to a published vocabulary (see its
  `validate_publishable_last_error/1`), and that clamp is the safety property
  keeping a raw transport term — which carries the SMTP relay host — off a page
  every team admin can read. A batched write that skipped the changeset would
  delete that property silently while looking like a pure performance change. So
  EVERY entry is run through the changeset and a row that does not validate is
  DROPPED and logged; only the survivors are inserted.

  The map that is validated is the map that is inserted — the entry is not
  rebuilt from `changeset.changes`, because `cast/3` omits a value equal to the
  schema's own default (`channel: "email"`, `attempts: 0`), and an insert built
  from `changes` would therefore write a different row than the one that passed
  validation.

  `insert_all` runs no `assoc_constraint`, so an unknown `team_id` raises a
  `Postgrex.Error` here where `Repo.insert/1` used to return an error tuple.
  `record/4`'s `rescue` catches it and answers `0`, which is the same count that
  path produced before.
  """
  @spec insert_suppressed([map()]) :: non_neg_integer()
  def insert_suppressed([]), do: 0

  def insert_suppressed(rows) when is_list(rows) do
    now = DateTime.utc_now()

    entries =
      rows
      |> Enum.filter(&publishable?/1)
      |> Enum.map(fn attrs ->
        attrs
        |> Map.take(@insertable_fields)
        |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})
      end)

    case entries do
      [] ->
        0

      entries ->
        {written, _} = Repo.insert_all(Delivery, entries)
        written
    end
  end

  defp publishable?(attrs) do
    case Delivery.changeset(%Delivery{}, attrs) do
      %Ecto.Changeset{valid?: true} ->
        true

      %Ecto.Changeset{} = changeset ->
        Logger.error(
          "Notifications.Withhold: refused a suppressed delivery: " <>
            "#{inspect(changeset.errors)}"
        )

        false
    end
  end
end
