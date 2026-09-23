defmodule BarkparkWeb.SessionAutolog do
  @moduledoc """
  Server-side session auto-log (session-handoff design §5b, v1.5 —
  task-bc34e83515bbd91f).

  When a request names a `type:session` document in the
  `x-barkpark-session-doc` header, the two write doors Barkpark itself
  witnesses append the matching event to that session's trail, so an agent
  no longer has to log them by hand:

    * `POST /v1/tasks/:doc_id/close` → `"task-closed"`, `ref` = the task
      doc_id, `note` = the lifecycle outcome it closed to;
    * `POST /v1/plugins/bulldocs/papers` → `"paper-published"`, `ref` = the
      published paper slug.

  The append is `Barkpark.Content.Sessions.append_event/5` — the SAME
  advisory-lock + CAS writer the explicit `POST /bulldocs/sessions/:slug/events`
  door uses, so an auto-logged event is byte-shaped like a hand-logged one
  (`ts` server-minted, `kind` from `Sessions.event_kinds/0`).

  ## Why not `x-barkpark-session`

  The design paper named the header `X-Barkpark-Session`. That name was taken
  after the paper was written: it now carries the SECRET claim-session key
  (`Barkpark.Tasks.SessionId`; `TasksController.session_id/2` reads it and the
  bp CLI sends it on every call). Reusing it would make one header mean two
  things — a secret the server must never store, and a public slug it writes
  into a document — and every bp call would suddenly look like it named a
  session doc. The session-DOC binding therefore rides its own header.

  ## Best-effort, inline after commit

  A session log NEVER blocks the milestone that triggered it (§5 error
  handling). This runs INLINE, after the primary write has committed and
  before the response is rendered — not in a spawned task — because:

    * the primary write is already durable (`Tasks.Close.close_with_receipt/3`
      and `Content.upsert_paper/1` have returned `{:ok, _}`), so nothing here
      can roll it back;
    * an async task would outlive the request process, lose the event on a
      restart, and sit outside the test sandbox's connection ownership — an
      untestable log path is how a "best-effort" log becomes a "never" log;
    * the cost is one scoped read + one `UPDATE` under a per-slug advisory
      lock that only other session writers ever take.

  Every failure — missing/blank header, unknown or out-of-scope slug, CAS
  loss, or a raise from a corrupt row — is logged and swallowed. `record/5`
  never raises and never changes the response.

  ## Scope

  The caller passes the tenant scope its OWN door resolved; the lookup runs
  through `Content.get_blocks_doc/4`, so a slug outside that scope reads as
  `:not_found` and is skipped. A header is a pointer, never a credential: it
  cannot reach a session the caller's scope cannot already read.
  """

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.Sessions

  @header "x-barkpark-session-doc"
  @max_slug_bytes 200

  @doc "The request header carrying the session-doc slug."
  def header, do: @header

  @doc """
  Append `kind` (with `attrs`' `"ref"`/`"note"`) to the session named by the
  request's `x-barkpark-session-doc` header, scoped by `scope_opts`.

  Returns `:skipped` (no header), `:ok` (appended) or `{:error, reason}`
  (logged, swallowed). Never raises.
  """
  @spec record(Plug.Conn.t(), binary(), map(), keyword()) :: :ok | :skipped | {:error, term()}
  def record(conn, kind, attrs, scope_opts) do
    case session_slug(conn) do
      nil ->
        :skipped

      {:invalid, reason} ->
        warn(reason, nil, kind)

      slug ->
        append(slug, kind, attrs, scope_opts)
    end
  end

  defp append(slug, kind, attrs, scope_opts) do
    case Sessions.append_event(slug, kind, attrs, Content.paper_default_dataset(), scope_opts) do
      {:ok, %{count: count}} ->
        Logger.info("session autolog: #{kind} ref=#{attrs["ref"]} -> #{slug} (#{count} events)")
        :ok

      {:error, reason} ->
        warn(reason, slug, kind)
    end
  rescue
    e -> warn({:raised, Exception.message(e)}, slug, kind)
  catch
    kind_of, reason -> warn({kind_of, reason}, slug, kind)
  end

  defp session_slug(conn) do
    case Plug.Conn.get_req_header(conn, @header) do
      [value | _] ->
        case String.trim(value) do
          "" -> nil
          slug when byte_size(slug) > @max_slug_bytes -> {:invalid, :slug_too_long}
          slug -> if String.valid?(slug), do: slug, else: {:invalid, :slug_not_utf8}
        end

      [] ->
        nil
    end
  end

  defp warn(reason, slug, kind) do
    Logger.warning(
      "session autolog skipped: #{kind} -> #{inspect(slug)}: #{inspect(reason)} " <>
        "(the primary write succeeded; session logging never blocks it)"
    )

    {:error, reason}
  end
end
