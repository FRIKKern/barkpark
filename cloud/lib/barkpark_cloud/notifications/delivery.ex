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

  ## `unconfirmed` — the response was LOST, not refused (ccpca-bl)

  The rule above cuts BOTH ways, and the chat path was breaking it in the other
  direction. `Notifications.post_chat/6` stamped `"failed"` on its transport-error
  arm, including the case where the request was written and no response ever came
  back. `"failed"` is a claim about what the RECEIVER did, and that arm measured
  nothing about the receiver: with `ChatNotificationWorker`'s `max_attempts: 4`
  the message may have been processed once, or four times, and the row said it
  was never delivered.

  `unconfirmed` is the word for exactly that. It is not the `"delivered"` the
  moduledoc refuses — it is the OPPOSITE move, a word that claims LESS than
  `failed` rather than more, and it needs no new evidence source because ignorance
  is what we actually have. `failed` keeps its meaning for every arm that DID read
  a verdict off the wire: a 4xx/5xx status, a DNS failure, a refused connection, a
  TLS failure, a connect-phase timeout. Narrow on purpose — see
  the private `response_lost?` predicate in `Notifications`, which names its one member.

  No historical row is rewritten. It costs no migration for the same reason
  `suppressed` did not: the column is `character varying(255)` with no CHECK.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias BarkparkCloud.Notifications.DeliveryReason

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending sent failed suppressed unconfirmed)
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
    # dr-w34: the SHA-256 (hex) of the rendered subject + bodies handed to the
    # transport. NULL means this send was not fingerprinted — see
    # `content_digest/1` and `content_proof_meaning/1`.
    field :content_sha256, :string
    # dr-w29: the rendered subject VERBATIM, and the numeric block parsed out of
    # it. Both NULL for any send whose caller did not hand the receipt its
    # `%Swoosh.Email{}`. See `content_subject/1`, `content_counts/1` and the
    # RETENTION RULING above them — these are the only two columns on this table
    # that carry rendered prose or rendered numbers, and both are fenced.
    field :content_subject, :string
    field :content_counts, :map

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
    "suppressed" => "Barkpark decided not to send this one; see the reason.",
    "unconfirmed" =>
      "Barkpark sent this and never got a response — it may have arrived, possibly " <>
        "more than once (the send is retried). Nobody refused it; we simply do not know."
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

  ## ── dr-w34: WHAT THIS RECEIPT CARRIED ────────────────────────────────────

  # The canonicalisation version. It is INSIDE the hashed bytes, so a future
  # change to what gets covered produces a different digest for the same email
  # rather than a silently-incomparable one: an old row and a new row can never
  # accidentally agree across a format change.
  @content_digest_version "bpdlv1"

  @doc """
  The content fingerprint of ONE rendered message — SHA-256, lowercase hex, of a
  canonical envelope over `subject`, `text_body` and `html_body`.

  ## Why this exists

  `notification_deliveries` stores an address, a transport verdict and a
  carrier. It has never stored a SENTENCE, so a delivery row proves a send
  HAPPENED and can never prove what it SAID (dr-w34). The recovery routes are
  gone too: `cloud-postfix-1` is recreated on every control-plane deploy, so the
  SMTP trace of any given send has a lifetime measured in hours.

  ## Why a hash and not the body

  Retention. A digest body names sites, environments and per-team deploy volume,
  and `notification_deliveries` is read cross-team by
  `/v1/operator/deliveries` — storing rendered bodies there would re-open the
  disclosure `deliver_fleet_digest/1` partitions its payload to prevent. A hash
  proves identity without retaining prose: whoever CLAIMS what the mail said
  holds the render, so they re-render, hash, and compare. What it cannot do is
  reconstruct a body nobody kept, and that limit is the price of the choice.

  ## What is covered, and what deliberately is not

  Covered: subject, text body, html body — everything a reader of the message
  sees. NOT covered: `to` / `from`. The recipient is already its OWN column on
  the same row (so folding it in would prove nothing new and would stop a render
  being checked without knowing the address), and `from` is `Mailer.from()`, a
  constant. A `nil` body and an empty-string body hash alike, because they
  render alike.

  Returns `nil` for anything that is not a `%Swoosh.Email{}` — a caller with no
  message in hand must leave the column NULL rather than store a digest of
  nothing.
  """
  @spec content_digest(Swoosh.Email.t() | any()) :: String.t() | nil
  def content_digest(%Swoosh.Email{} = email) do
    :sha256
    |> :crypto.hash(content_envelope(email))
    |> Base.encode16(case: :lower)
  end

  def content_digest(_other), do: nil

  # The exact bytes that get hashed. Newline-separated with the version first;
  # every part is length-prefixed so no combination of subject and body can be
  # re-cut into a different combination with the same envelope.
  defp content_envelope(%Swoosh.Email{} = email) do
    [
      @content_digest_version,
      part(email.subject),
      part(email.text_body),
      part(email.html_body)
    ]
    |> Enum.join("\n")
  end

  defp part(value) when is_binary(value), do: "#{byte_size(value)}:" <> value
  defp part(_value), do: "0:"

  @doc """
  Does `delivery`'s recorded fingerprint match `email`?

  THE POINT OF THE COLUMN, as a predicate rather than a comparison a caller has
  to remember to write. `true` only when the row carries a digest AND that digest
  equals the one this message renders to. A row with no fingerprint answers
  `false` — an unfingerprinted receipt has not proved anything, and returning
  `true` for it would make "unproven" indistinguishable from "proven".
  """
  @spec content_matches?(t(), Swoosh.Email.t() | any()) :: boolean()
  def content_matches?(%__MODULE__{content_sha256: stored}, email) when is_binary(stored) do
    case content_digest(email) do
      digest when is_binary(digest) -> Plug.Crypto.secure_compare(stored, digest)
      nil -> false
    end
  end

  def content_matches?(%__MODULE__{}, _email), do: false

  @doc """
  The one sentence that says what this row's `content_sha256` proves — the
  `status_meaning/1` precedent, for the same reason: an absence rendered as a
  blank is indistinguishable from a confident claim.
  """
  @spec content_proof_meaning(String.t() | nil) :: String.t()
  def content_proof_meaning(digest) when is_binary(digest) do
    "SHA-256 of the subject and bodies handed to the transport. " <>
      "Re-render the message and hash it to check a claim about what this send said; " <>
      "the body itself is deliberately not stored."
  end

  def content_proof_meaning(_digest) do
    "Not fingerprinted — this send predates the content digest or was recorded " <>
      "without the rendered message in hand. What it said cannot be proved from this row."
  end

  # dr-w29 — THE RETENTION FENCES, as data. `content_retention_ruling/0` below
  # is the prose; these three are what actually bind.
  @subject_retention_limit 512
  @content_count_words ~w(current behind diverged ahead_of_main unmeasured paused)
  # `<digits> <word[ word…]>` — the shape `DigestEmail.subject/1` prints its
  # rungs in. Anchored on nothing, because the subject is a sentence and not a
  # format string; the CLAMP is the vocabulary above, not this pattern.
  @count_pattern ~r/(\d+)\s+([A-Za-z]+(?:\s+[A-Za-z]+)*)/

  ## ── dr-w29: WHAT IT SAID, IN THE NARROWEST FORM THAT SAYS IT ─────────────

  @doc """
  THE RETENTION RULING for `content_subject` and `content_counts` (dr-w29 c1),
  as a function so it is quotable by a test and by the console rather than
  living in a PR body nobody can grep.

  Written BEFORE the columns, because storing what the platform said to people
  is a retention decision and not a technical one.

  ## What is retained

    * `content_subject` — the `Subject:` header of the message handed to the
      transport, VERBATIM, and only when it is at or under
      #{@subject_retention_limit} bytes. Over that it is NOT stored at all: a
      truncated sentence reads as a complete one, and a half-subject in an audit
      column is worse than an absence that says it is an absence.
    * `content_counts` — a map whose KEY SPACE IS CLOSED
      (`content_count_words/0`) and whose values are INTEGERS ONLY. It is parsed
      back OUT of the rendered subject, so it is what a reader saw, not what the
      renderer was handed.

  ## What is deliberately NOT retained, and why the line is here

  THE BODY. dr-w34 ruled it out and the reason has not weakened: a digest body
  names site names, environments, per-window deploy volume and failure rates,
  and `notification_deliveries` is read CROSS-TEAM by
  `GET /v1/operator/deliveries`. Storing bodies there would re-open, from
  behind, the disclosure `deliver_fleet_digest/1` partitions its payload per
  team to prevent. `content_sha256` already proves the body: whoever claims what
  a send said holds the render, re-renders, and compares.

  The subject clears that bar where the body does not, and the difference is
  measurable rather than asserted. `DigestEmail.subject/1` renders
  `"Your Barkpark instances — <n> current / <n> behind / …"` — the recipient
  team's own rung counts and NOTHING else. No site name, no environment, no
  release string, no address, no other team's numbers. The counts are already
  the recipient's own, on a row already stamped with the recipient's `team_id`.

  ## Who can read it

  Exactly the two routes that already read this row, with no new audience:

    * `GET /v1/notifications/deliveries` — team-scoped, and a non-admin member
      is further fenced to rows whose `recipient` is their OWN address. A
      non-member of the team reads nothing on this route at all.
    * `GET /v1/operator/deliveries` — platform operator only, cross-team, and
      already cross-team for recipient ADDRESSES before these columns existed.

  ## For how long

  For the life of the delivery row. There is no retention sweeper over
  `notification_deliveries` today — that is a stated gap, not a silence: these
  columns inherit whatever policy the table eventually gets, and the fences
  above (closed key space, integer values, verbatim-or-absent subject) are what
  bound the exposure in the meantime.

  ## The blast radius, as of this commit

  ONE event. `record_delivery/7` fills these columns only from an `email`
  argument, and `deliver_fleet_digest/1` is the only call site that passes one
  (every transactional and alert caller passes six arguments). So the only rows
  that carry a subject are `event: "fleet_digest"` rows.
  """
  @spec content_retention_ruling() :: String.t()
  def content_retention_ruling do
    "Retained: the rendered subject verbatim (at most #{@subject_retention_limit} bytes, " <>
      "or nothing) and an integer-only count map over a closed key set. NOT retained: the " <>
      "body — it names sites, environments and deploy volume, and this log is read " <>
      "cross-team by the operator route. Readable by the recipient's own team " <>
      "(members self-scoped to their own address) and by a platform operator; kept for the " <>
      "life of the delivery row."
  end

  @doc """
  The subject of the message handed to the transport, or `nil`.

  VERBATIM OR ABSENT — never truncated. See `content_retention_ruling/0`.
  """
  @spec content_subject(Swoosh.Email.t() | any()) :: String.t() | nil
  def content_subject(%Swoosh.Email{subject: subject}) when is_binary(subject) do
    if byte_size(subject) <= @subject_retention_limit, do: subject, else: nil
  end

  def content_subject(_other), do: nil

  @doc "The retention byte ceiling on `content_subject`."
  @spec subject_retention_limit() :: pos_integer()
  def subject_retention_limit, do: @subject_retention_limit

  @doc """
  The closed key vocabulary `content_counts/1` will store. Anything else the
  subject says is DROPPED rather than recorded.

  This is the fence that makes the column structurally incapable of becoming a
  prose sink: a future subject change cannot smuggle a sentence in as a key,
  because a key outside this list is not written and `changeset/2` refuses a row
  that carries one.
  """
  @spec content_count_words() :: [String.t()]
  def content_count_words, do: @content_count_words

  @doc """
  The NUMERIC BLOCK of the message handed to the transport — parsed back out of
  the RENDERED SUBJECT, not read off the summary that produced it.

  That direction is the whole point. A block copied from
  `DigestEmail.summary/2`'s map would prove the renderer received those numbers
  and never that it PRINTED them; a subject that dropped a rung, or printed the
  wrong one, would be recorded as correct. Reading the render back means the
  stored numbers are the numbers a human saw, which is what a receipt is for.

  Returns `nil` — not `%{}` — when the subject states no count this vocabulary
  knows, so "this send had no numeric block" and "this send's block was empty"
  are not the same value.
  """
  @spec content_counts(Swoosh.Email.t() | any()) :: %{optional(String.t()) => integer()} | nil
  def content_counts(%Swoosh.Email{subject: subject}) when is_binary(subject) do
    counts =
      @count_pattern
      |> Regex.scan(subject)
      |> Enum.reduce(%{}, fn [_whole, digits, words], acc ->
        key = words |> String.downcase() |> String.replace(~r/\s+/, "_")

        # FIRST OCCURRENCE WINS. A later stray phrase that happens to end in a
        # vocabulary word must not overwrite the count the subject actually led
        # with.
        if key in @content_count_words and not Map.has_key?(acc, key) do
          Map.put(acc, key, String.to_integer(digits))
        else
          acc
        end
      end)

    if map_size(counts) == 0, do: nil, else: counts
  end

  def content_counts(_other), do: nil

  @doc """
  The one sentence that says what this row's stored subject and counts are — the
  `status_meaning/1` / `content_proof_meaning/1` precedent, for the third time
  and the same reason: a reader that renders a blank for an absence is
  indistinguishable from one that renders a confident claim.
  """
  @spec content_block_meaning(String.t() | nil, map() | nil) :: String.t()
  def content_block_meaning(subject, counts) when is_binary(subject) or is_map(counts) do
    said =
      if is_binary(subject),
        do: "The subject line is stored verbatim. ",
        else: "No subject was stored for this send. "

    numbers =
      if is_map(counts) and map_size(counts) > 0 do
        "The counts were read back OUT of the rendered subject, so they are what a " <>
          "reader saw. "
      else
        "This send stated no count this version knows how to read back. "
      end

    said <>
      numbers <>
      "The body itself is not stored — see content_sha256 to check a claim " <>
      "about what it said."
  end

  def content_block_meaning(_subject, _counts) do
    "Nothing about this send's content was stored beyond its fingerprint — the caller " <>
      "recorded the receipt without the rendered message in hand. What it said cannot be " <>
      "read from this row."
  end

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
      :carrier,
      :content_sha256,
      :content_subject,
      :content_counts
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
    |> validate_length(:content_subject, max: @subject_retention_limit, count: :bytes)
    |> validate_retained_counts()
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

  # dr-w29 — THE FENCE THAT OUTLIVES `content_counts/1`. The parser above already
  # drops everything outside the vocabulary, but a parser is one writer and a
  # column is forever: this refuses the row itself, so a future call site that
  # builds the map by hand cannot turn an integer column into a prose sink by
  # forgetting the rule. Keys must be in the closed vocabulary; values must be
  # integers. `nil` is always allowed — it is the honest value for a send whose
  # message the receipt never saw.
  defp validate_retained_counts(changeset) do
    validate_change(changeset, :content_counts, fn :content_counts, value ->
      cond do
        not is_map(value) ->
          [content_counts: "must be a map of count words to integers"]

        Enum.all?(value, fn {k, v} -> to_string(k) in @content_count_words and is_integer(v) end) ->
          []

        true ->
          [
            content_counts:
              "may only carry integer counts keyed by #{Enum.join(@content_count_words, ", ")}"
          ]
      end
    end)
  end
end
