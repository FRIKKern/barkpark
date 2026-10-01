defmodule BarkparkWeb.ExportController do
  @moduledoc """
  The backup verb: streams every document in a dataset as NDJSON.

  The response status is committed the moment `send_chunked/2` runs, so a
  failure part-way through can never be re-reported as a status code. That
  makes the honest-outcome rule load-bearing here: when the socket dies
  mid-stream the export must HALT and say, in the log, exactly how far it got
  — never raise, and never fall silent leaving the owner with a truncated
  backup that looks complete.

  Two mechanisms keep that promise, in this order:

    1. **Decide what can be decided BEFORE the first byte.** `?type` is pure
       query-string input on a route that declares no `type` path param, so a
       client can hand us `?type[]=post` (a list) or `?type[k]=v` (a map).
       Either shape is truthy, so it used to be pinned straight into
       `d.type == ^type` against a `:string` column — `Repo.stream` raised an
       `Ecto.Query.CastError` INSIDE the already-chunked response, where
       `phoenix_ecto`'s CastError→400 mapping cannot reach it. The caller got a
       200 with an empty body and no terminating chunk; nothing was logged.
       `validate_type/1` now refuses the request with a real 400 while the conn
       is still unchunked.

    2. **Say so when the stream fails anyway.** Everything after
       `send_chunked/2` — row decoding, per-type schema resolution, envelope
       rendering, JSON encoding — can still raise, and by then no status change
       is possible. `stream_export/3` rescues, logs how far the export got, and
       writes a terminating `{"_barkpark_export":"incomplete", …}` NDJSON line
       so a restore can tell a truncated dump from a complete one in-band. The
       marker deliberately carries no `_id`/`_type`, so it can never be mistaken
       for a document.
  """
  use BarkparkWeb, :controller

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Repo
  alias BarkparkWeb.{AnonPerspective, ErrorResponse, ReadPerspective}

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  # task-c14e213b4a7b0ef1: `?perspective` was never read, so `bp export
  # --perspective published`, the raw route and the SDK's
  # exportDataset({perspective: "published"}) all streamed every draft.
  @perspectives ["published", "drafts", "raw"]

  def export(conn, %{"dataset" => dataset} = params) do
    with {:ok, type} <- validate_type(params["type"]),
         {:ok, perspective} <- resolve_perspective(conn, params) do
      stream_export(conn, dataset, type, perspective)
    else
      {:refuse_perspective, value} ->
        # Refused before `send_chunked/2`, the same door and envelope every
        # other read route uses for an unsupported `?perspective`.
        ReadPerspective.refuse(conn, value, @perspectives,
          message:
            "unsupported perspective #{inspect(value)} for export — supported values are " <>
              "published, drafts and raw"
        )

      :error ->
        # Refused BEFORE `send_chunked/2` — the status line is still ours to
        # choose, which is the whole point of validating here rather than
        # letting the cast blow up inside the chunked body.
        ErrorResponse.emit_custom(
          conn,
          400,
          "invalid_filter",
          "the `type` filter must be a single string — a repeated or nested " <>
            "`type` parameter (`?type[]=post`, `?type[k]=post`) is not supported"
        )
    end
  end

  # `type` is query-string input with nothing to override it, so its SHAPE is
  # attacker-chosen. Only a bare string (or nothing) may reach the query.
  defp validate_type(nil), do: {:ok, nil}
  defp validate_type(type) when is_binary(type), do: {:ok, type}
  defp validate_type(_other), do: :error

  # WHICH LENS, AND WHO GETS WHICH DEFAULT.
  #
  # An explicit, supported `?perspective` is honoured, except that a caller
  # `AnonPerspective` pins to published (a `public-read` token or no token) is
  # pinned here too. The `:require_token` pipeline already refuses those callers
  # this route, so the pin is defence in depth, not the fence.
  #
  # No `?perspective` means a per-tier default. docs/api-v1.md never stated
  # one, and the SDK documents "server default raw":
  #
  #   * an EDITOR (a write/admin token, or an admin/owner/editor session) gets
  #     `raw`. That is the backup this verb exists for, and it is byte-identical
  #     to every export taken before this change.
  #   * everyone else (a `read` token) gets `published`, the same default
  #     `/v1/data/query` has always given that tier. A read-only reader who
  #     wants drafts asks for them, exactly as on the query route.
  defp resolve_perspective(conn, params) do
    case ReadPerspective.unsupported(params, @perspectives) do
      nil ->
        cond do
          AnonPerspective.anon_pinned?(conn) -> {:ok, :published}
          is_binary(params["perspective"]) -> {:ok, AnonPerspective.parse(params["perspective"])}
          editor?(conn) -> {:ok, :raw}
          true -> {:ok, :published}
        end

      bad ->
        {:refuse_perspective, bad}
    end
  end

  @editor_roles ~w(write admin owner editor)

  defp editor?(conn) do
    case Keyword.get(scope_opts(conn), :caller_context) do
      %CallerContext{is_admin: true} -> true
      %CallerContext{roles: roles} when is_list(roles) -> Enum.any?(roles, &(&1 in @editor_roles))
      _ -> false
    end
  end

  defp stream_export(conn, dataset, type, perspective) do
    opts = if(type, do: [type: type], else: []) ++ [perspective: perspective] ++ scope_opts(conn)

    conn =
      conn
      |> put_resp_content_type("application/x-ndjson")
      |> send_chunked(200)

    # The delivered count has to survive a raise out of the reduce (the
    # accumulator does not), so it lives in a counter. "How far did it get?" is
    # the one fact the operator needs from a truncated backup.
    delivered = :counters.new(1, [])

    try do
      # `Content.export_stream/2` is backed by `Repo.stream` (a DB cursor), which
      # Ecto REQUIRES to run inside a transaction — so this wrapper cannot be
      # narrowed away. It stays exactly as wide as it was; the pool-hold that
      # `pds-bl-export-pool-starvation` tracks is untouched by this change and
      # that row is NOT closed by it. What changes is that the transaction now
      # ENDS on a hangup instead of being torn down by a raise.
      {:ok, {conn, outcome}} =
        Repo.transaction(fn ->
          Content.export_stream(dataset, opts)
          |> Enum.reduce_while({conn, :ok}, fn doc, {acc, _} ->
            line = Jason.encode!(doc) <> "\n"

            case chunk(acc, line) do
              {:ok, acc} ->
                :counters.add(delivered, 1, 1)
                {:cont, {acc, :ok}}

              # The client hung up (`:closed`) or the socket errored. Halting
              # closes the cursor and returns the conn Phoenix already owns; a
              # strict match here would instead raise a MatchError inside the
              # open transaction while holding its DB connection.
              {:error, reason} ->
                {:halt, {acc, {:error, reason}}}
            end
          end)
        end)

      case outcome do
        :ok ->
          conn

        {:error, reason} ->
          Logger.warning(
            "export truncated: client socket closed mid-stream " <>
              "(dataset=#{dataset} type=#{type || "*"} " <>
              "delivered=#{count(delivered)} reason=#{inspect(reason)}). " <>
              "The 200 was already on the wire — this backup is INCOMPLETE."
          )

          conn
      end
    rescue
      error ->
        # A raise reaches here only AFTER `send_chunked/2`, so re-raising would
        # just replace a silent truncated 200 with a silent truncated 200 plus a
        # `Plug.Conn.AlreadySentError` in the error path. Report it instead: to
        # the operator in the log, and to the caller in-band via the marker.
        n = count(delivered)

        Logger.warning(
          "export failed mid-stream: " <>
            "(dataset=#{dataset} type=#{type || "*"} delivered=#{n}). " <>
            "The 200 was already on the wire — this backup is INCOMPLETE. " <>
            Exception.format(:error, error, __STACKTRACE__)
        )

        mark_incomplete(conn, n)
    end
  end

  defp count(counter), do: :counters.get(counter, 1)

  # The terminating NDJSON line that distinguishes a truncated dump from a
  # complete one. No `_id`/`_type`, so a restore keyed on document identity
  # cannot ingest it as content.
  defp mark_incomplete(conn, delivered) do
    marker =
      Jason.encode!(%{
        "_barkpark_export" => "incomplete",
        "_delivered" => delivered,
        "_error" => "the export failed mid-stream; this backup is INCOMPLETE"
      }) <> "\n"

    case chunk(conn, marker) do
      {:ok, conn} -> conn
      # The socket is gone too — nothing left to tell the caller with. The log
      # line above already carries the outcome.
      {:error, _reason} -> conn
    end
  end
end
