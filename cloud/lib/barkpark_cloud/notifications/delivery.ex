defmodule BarkparkCloud.Notifications.Delivery do
  @moduledoc """
  A durable record of one notification send — one row per recipient per event.
  Modeled on `Barkpark.Webhooks.Delivery` (api/): `status` / `attempts` /
  `last_error`. This is the observability surface Coolify lacks (it leans on
  Laravel's `failed_jobs`); the webhook precedent says a CMS wants a first-class,
  team-scoped delivery log.

  v1 sends synchronously and stamps `status` ("sent" | "failed") immediately. The
  `attempts` / `last_error` shape is the future retry seam: when cloud/ gains
  Oban a worker re-drives `status: "failed"` rows with backoff.

  ## `suppressed` — the log of DECISIONS, not only of ATTEMPTS (wave 32 S2)

  `pending | sent | failed` can only describe a send that was ATTEMPTED, because
  both writers run after the transport returns. A branch that DECIDES not to send
  — the reaper's `@reap_alert_cap` tail — was therefore unrepresentable, and the
  26th owner of a cluster-wide incident read a log that said nothing at all.
  `suppressed` is that fourth outcome: the alert existed, we withheld it, and the
  row says so. It costs one word and NO migration —
  `notification_deliveries.status` is `character varying(255)` with no CHECK and
  no PG enum, and both `delivery_json/1` consumers project `status` verbatim.

  A `suppressed` row is written by `Notifications.Withhold` ONLY, one row per
  team member with that member's own address as `recipient`, so "was I notified?"
  is answerable by the person who was not.

  ## `sent` means ACCEPTED, not DELIVERED (dr-w26)

  `record_delivery/6` stamps `"sent"` on the `{:ok, _}` arm of `Mailer.deliver/1`.
  That tuple means the SWOOSH ADAPTER handed the message off without raising —
  for the platform SMTP carrier, that the relay answered `250` at the submission
  hop. It is not a claim the message left the box, and it is emphatically not a
  claim it reached a human. `http_status` does not close the gap either: it is
  NULL for every email row by construction (it is the chat providers' HTTP code).

  Nobody was lying; the word was just read as more than it says. On 2026-08-08
  thirty outage alerts carried `status=sent, http_status=NULL`, and when the
  question "did the tenant actually hear about the outage?" was finally asked,
  the answer was level-3 hearsay. The artefact that could have settled it,
  Postfix's maillog, did not exist: on that box `postconf maillog_file` was
  EMPTY with no syslog daemon running, so no per-message log was ever written
  (`tooling/grip/ledger/digest-delivered-and-freeze-date-w27-2026-08-09.md`
  R3). That batch is UNRECOVERABLE — a missing writer cannot be re-read.

  Two separate fixes came out of it, both forward-looking. The writer exists
  now (`cloud/postfix/entrypoint.sh` sets `maillog_file`), and it is DURABLE
  now — that log goes to the `postfix_log` volume, so the next control-plane
  recreate does not take it, which `cloud/postfix/check-maillog.sh --recreate`
  proves. Neither retrieves 2026-08-08.

  THE HONEST FIX IS A SENTENCE, NOT A NEW WORD. A `"delivered"` status would
  need a writer that KNOWS about delivery — an upstream relay receipt or a
  bounce/DSN feed — and this system has neither yet. Minting the word without
  the evidence would repeat the exact defect: a stronger-sounding claim resting
  on the same weak measurement. And no historical row may be rewritten: every
  existing `sent` was accurate about what it measured. So the meaning ships
  instead, as `status_meaning/1` — one sentence per status, carried in the API
  payload beside `status` (`Web.Router.delivery_json/1`) so no reader can pick
  up the word without the caveat attached to it.

  When a receipt source does arrive, `"delivered"` becomes a real fourth word
  and `status_meaning/1` is where its sentence goes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias BarkparkCloud.Notifications.DeliveryReason

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending sent failed suppressed)
  @kinds ~w(alert transactional)
  # notifications-chat widened this beyond email to the chat egress channels.
  @channels ~w(email discord slack telegram pushover webhook)

  # cch-w52-s3 — THE CARRIER: what actually carried this send, as opposed to
  # `channel`, which is the EGRESS FAMILY. Every email transport collapses to the
  # single channel `"email"`, so before this field a row reading `sent` could not
  # answer "sent by what": a team on `transport: "smtp"` whose `smtp_override/1`
  # failed to decrypt rode the PLATFORM mailer and got a row byte-identical to a
  # carried one.
  #
  # THREE MEMBERS, and the third is not a placeholder:
  #
  #   * `platform`   — Barkpark's own mailer. Every `kind: "transactional"` send
  #                    rides it by construction (`Mailer`'s moduledoc), and so
  #                    does an `smtp` team whose override could not be built.
  #   * `team_smtp`  — the team's OWN relay actually carried it.
  #   * `unknown`    — a FIRST-CLASS state, never a NULL and never a blank. Rows
  #                    written before this field existed cannot prove their
  #                    carrier (charter D362 forbids inferring one from a
  #                    settings row that has no history table), and the console
  #                    renders this as a sentence rather than omitting the
  #                    segment.
  #
  # NO `api` MEMBER. cch-w52-s1 deleted that transport because nothing ever
  # carried it; re-minting the word inside the fix that makes carriers legible
  # would repeat the crown defect.
  #
  # The write seam is `Notifications.deliver_alert/2`, which RETURNS the carrier
  # it used, and `record_delivery/6`, which stores it.
  @carriers ~w(platform team_smtp unknown)

  schema "notification_deliveries" do
    field :recipient, :string
    field :event, :string
    field :channel, :string, default: "email"
    field :kind, :string, default: "alert"
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_error, :string
    # notifications-chat: the provider HTTP status for a chat send (null for email).
    field :http_status, :integer
    field :carrier, :string

    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses
  def kinds, do: @kinds
  def carriers, do: @carriers

  @status_meanings %{
    "pending" => "Queued by Barkpark; no transport result yet.",
    "sent" =>
      "Accepted by the mail transport — NOT confirmed delivered to the recipient. " <>
        "Barkpark has no delivery receipt for email; check the relay log for the actual outcome.",
    "failed" => "The transport rejected or could not complete the send; see the reason.",
    "suppressed" => "Barkpark decided not to send this one; see the reason."
  }

  @doc """
  The one sentence that says what a `status` word actually MEASURED.

  Exists because `"sent"` reads as "arrived" and means "the transport took it"
  (see the moduledoc). Total over `statuses/0`, and total over the unknown
  string too — an unrecognised word gets an explicit "not a status this version
  knows" rather than `nil`, because a reader that renders a blank caveat is
  indistinguishable from one that renders a confident claim.
  """
  @spec status_meaning(String.t() | nil) :: String.t()
  def status_meaning(status) when is_binary(status) do
    Map.get(@status_meanings, status, "Not a status this version of Barkpark knows.")
  end

  def status_meaning(_status), do: "Not a status this version of Barkpark knows."

  def status_meanings, do: @status_meanings

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :team_id,
      :recipient,
      :event,
      :channel,
      :kind,
      :status,
      :attempts,
      :last_error,
      :http_status,
      :carrier
    ])
    # team_id is nullable: user-scoped identity emails (password-reset / verify /
    # email-change-code) belong to a user, not a team, so their delivery rows carry
    # no team_id (team-scoped alert/test/invite rows still set it).
    |> validate_required([:recipient, :event])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:channel, @channels)
    |> validate_inclusion(:carrier, @carriers)
    |> validate_publishable_last_error()
    |> assoc_constraint(:team)
  end

  # `last_error` is PUBLISHED — `Web.Router.delivery_json/1` serves it to every
  # team admin and `app.js` renders it VERBATIM — so the field is clamped to the
  # sentences this system is willing to say out loud, and a raw transport term
  # (which carries the SMTP relay host, see `DeliveryReason`) cannot be stored
  # even by a caller that forgets to classify.
  #
  # `validate_change`, NOT `validate_inclusion`: `DeliveryReason.label({:http_status,
  # n})` interpolates an unbounded integer family, so a flat member-of-list check
  # would reject every real chat-failure row.
  #
  # TWO VOCABULARIES, named together here so they cannot drift apart:
  #
  #   1. FAILURE reasons — `DeliveryReason`, every arm of which describes a send
  #      this system TRIED to make and that did not arrive ("The destination
  #      refused the connection"). Wave 35 S3 sharpened the boundary rather than
  #      moving it: `:not_configured` says the send "never started", because the
  #      transport refused to open a socket at all — still a send this system
  #      attempted, so still a `failed` row, never a withheld one.
  #   2. WITHHOLD reasons — `Notifications.Withhold`, for `status: "suppressed"`
  #      rows, where nothing was attempted at all. None of (1) can honestly say
  #      that, which is exactly why (2) exists as a separate set.
  #
  # `Withhold.labels/0` is called at RUNTIME on purpose: `Withhold` builds a
  # `%Delivery{}` struct and so compile-depends on this module; a compile-time
  # attribute here would close that cycle.
  defp validate_publishable_last_error(changeset) do
    validate_change(changeset, :last_error, fn :last_error, value ->
      if publishable_last_error?(value) do
        []
      else
        [last_error: "must be a classified delivery reason, not a raw transport term"]
      end
    end)
  end

  @failure_labels Enum.map(DeliveryReason.classes(), &DeliveryReason.label/1)
  # The one unbounded arm of vocabulary (1): the integer HTTP status is the only
  # value `DeliveryReason` ever lets escape.
  @http_status_label ~r/^The channel rejected the message \(HTTP \d+\)\.$/

  defp publishable_last_error?(value) when is_binary(value) do
    value in @failure_labels or
      value in BarkparkCloud.Notifications.Withhold.labels() or
      Regex.match?(@http_status_label, value)
  end

  defp publishable_last_error?(_value), do: false
end
