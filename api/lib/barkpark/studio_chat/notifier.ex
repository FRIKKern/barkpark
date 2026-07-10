defmodule Barkpark.StudioChat.Notifier do
  @moduledoc """
  The Studio-chat notification SEAM (studio-claude-chat wave 12, charter D69).

  When a session needs the operator (`:needs_you`) or finishes a turn while they
  are away (`:finished_while_away`), the runtime publishes an event through this
  seam. The seam applies two policies — per-event-kind **opt-out** and a
  per-session **debounce** (one mail per session per quiet period) — and then
  fans the event out to every configured **channel**. Today one channel ships:
  email over the existing Postfix/DKIM relay (the same `Barkpark.Mailer` the
  airdrop `GrantNotifier` uses). The channel list is data-driven so wave-13 can
  slot in Web Push / webhook (`scc-w13-notify-channels`) without touching the
  policy layer.

  ## Boundaries

    * **Fail-soft, no PII.** A down relay is logged by TYPE only (`kind` +
      `reason`) — never the recipient, title, or session content — and the call
      returns `{:error, reason}`. A notification is a courtesy, never load-bearing;
      the sidebar inbox strip (`scc-w12-needs-you`) is the durable surface.
    * **Deep link is public-origin only.** `BarkparkWeb.Endpoint.url()` fronts the
      link so it carries the DNS host + scheme, never an internal port (charter
      #1190 — the PHX public-url contract).
    * **The debounce lives in this GenServer, delivery lives in the caller.** The
      process serialises the per-session gate decision (race-free); the actual
      `Mailer.deliver` runs in whichever process called `notify/1`, so a
      Swoosh.Test mailbox assertion in a test lands in the test process.

  ## Event

  A plain map: `%{kind: :needs_you | :finished_while_away, session_id: String,
  title: String | nil, line: String | nil}`. `title` names the session in the
  subject; `line` is the one-line "what it's waiting on / what it finished".

  ## Wiring

  `scc-w12-needs-you` owns the away-detection + the decision to fire (it already
  derives `:needs_you` / idle transitions on `Recorder.activity_topic/0`). This
  module is the CHANNEL it calls — it deliberately does NOT subscribe to activity
  itself, so a session the operator is actively watching never spams a mail.
  """

  use GenServer

  import Swoosh.Email

  require Logger

  alias Barkpark.Mailer

  @from {"Barkpark", "no-reply@barkpark.cloud"}

  @kinds [:needs_you, :finished_while_away]

  # One mail per session per 15 minutes by default (config-overridable, and set
  # small in tests). Debounce is per SESSION, across kinds — a needs-you followed
  # by a finished-while-away inside the window is still one nudge.
  @default_quiet_period_ms 15 * 60 * 1_000

  @typedoc "A notification event handed to the seam."
  @type event :: %{
          required(:kind) => :needs_you | :finished_while_away,
          required(:session_id) => String.t(),
          optional(:title) => String.t() | nil,
          optional(:line) => String.t() | nil
        }

  # ── public API ────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Publish a notification event through the seam.

  Returns `:ok` on a delivered notification, `{:skipped, reason}` when a policy
  suppressed it (`:opted_out`, `:no_recipient`, `:debounced`), or
  `{:error, reason}` when a channel failed (already logged, fail-soft).
  """
  @spec notify(event()) :: :ok | {:skipped, atom()} | {:error, term()}
  def notify(%{kind: kind, session_id: session_id} = event)
      when kind in @kinds and is_binary(session_id) and session_id != "" do
    with :ok <- check_opt_out(kind),
         {:ok, recipient} <- recipient(),
         :ok <- gate(session_id) do
      dispatch(event, recipient, deep_link(session_id))
    end
  end

  def notify(_event), do: {:error, :invalid_event}

  @doc "The valid event kinds — the vocabulary the inbox model (`scc-w12-needs-you`) shares."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Test seam: clear the debounce ledger so a fresh test starts un-throttled."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # ── policy: opt-out ─────────────────────────────────────────────────────────

  # Per-event-kind opt-out. A kind listed in `:opted_out_kinds` is suppressed
  # before any channel runs — the extension point a per-recipient preference
  # store (wave-13) drops into without disturbing the debounce or the channels.
  defp check_opt_out(kind) do
    if kind in opted_out_kinds(), do: {:skipped, :opted_out}, else: :ok
  end

  # ── policy: debounce (serialised in the GenServer) ──────────────────────────

  defp gate(session_id) do
    GenServer.call(__MODULE__, {:gate, session_id})
  end

  # ── channels ────────────────────────────────────────────────────────────────

  # Fan out to every configured channel. `{module, function}` pairs are called
  # `fun(event, recipient, deep_link)`; the built-in email channel is the sole
  # default. Any channel error is fail-soft (logged by type in the channel) and
  # collapses to `{:error, reason}` for the whole call, but never raises.
  defp dispatch(event, recipient, deep_link) do
    Enum.reduce(channels(), :ok, fn {mod, fun}, acc ->
      case apply(mod, fun, [event, recipient, deep_link]) do
        {:ok, _} -> acc
        {:error, reason} -> keep_error(acc, reason)
      end
    end)
  end

  defp keep_error(:ok, reason), do: {:error, reason}
  defp keep_error({:error, _} = err, _reason), do: err

  @doc false
  # The email channel — GrantNotifier pattern: build → deliver → fail-soft with
  # type-only logging (never the recipient, title, or body). Public only so it
  # can sit in the `channels/0` `{module, function}` list.
  def deliver_email(%{kind: kind} = event, recipient, deep_link) do
    mail =
      new()
      |> to(recipient)
      |> from(@from)
      |> subject(subject_for(event))
      |> text_body(body_for(event, deep_link))

    case Mailer.deliver(mail) do
      {:ok, _meta} ->
        {:ok, mail}

      {:error, reason} ->
        Logger.error(
          "studio_chat notification email delivery failed: kind=#{kind} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp subject_for(%{kind: :needs_you} = event),
    do: "Claude needs you" <> title_suffix(event)

  defp subject_for(%{kind: :finished_while_away} = event),
    do: "Claude finished while you were away" <> title_suffix(event)

  defp title_suffix(%{title: title}) when is_binary(title) and title != "",
    do: " — " <> title

  defp title_suffix(_event), do: ""

  defp body_for(%{kind: :needs_you} = event, deep_link) do
    """
    A Claude session on Barkpark is waiting on you#{line_clause(event)}.

    Open the session to respond:

    #{deep_link}

    You're getting this because Studio-chat notifications are on. Reply in the
    chat and the session picks up right where it left off.
    """
  end

  defp body_for(%{kind: :finished_while_away} = event, deep_link) do
    """
    A Claude session on Barkpark finished while you were away#{line_clause(event)}.

    Pick up where it left off:

    #{deep_link}

    You're getting this because Studio-chat notifications are on.
    """
  end

  defp line_clause(%{line: line}) when is_binary(line) and line != "", do: " (#{line})"
  defp line_clause(_event), do: ""

  defp deep_link(session_id) do
    BarkparkWeb.Endpoint.url() <> "/studio/chat/" <> session_id
  end

  # ── config ─────────────────────────────────────────────────────────────────

  defp config, do: Application.get_env(:barkpark, __MODULE__, [])

  # The operator's inbox. nil (unset) is a first-class "no recipient" — the seam
  # skips rather than raising, so an instance that never configured a notify
  # address stays silent instead of crashing the runtime.
  defp recipient do
    case config()[:to] do
      to when is_binary(to) and to != "" -> {:ok, to}
      _ -> {:skipped, :no_recipient}
    end
  end

  defp opted_out_kinds, do: config()[:opted_out_kinds] || []

  defp channels, do: config()[:channels] || [{__MODULE__, :deliver_email}]

  defp quiet_period_ms, do: config()[:quiet_period_ms] || @default_quiet_period_ms

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{sent: %{}}}

  @impl true
  def handle_call({:gate, session_id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    quiet = quiet_period_ms()

    case Map.get(state.sent, session_id) do
      last when is_integer(last) and now - last < quiet ->
        {:reply, {:skipped, :debounced}, state}

      _ ->
        # Prune entries older than the quiet period while we're here — an
        # expired stamp can never debounce again, so keeping it would only
        # grow the ledger by one dead entry per session id, forever.
        sent =
          for {sid, ts} <- state.sent, now - ts < quiet, into: %{}, do: {sid, ts}

        {:reply, :ok, %{state | sent: Map.put(sent, session_id, now)}}
    end
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | sent: %{}}}
  end
end
