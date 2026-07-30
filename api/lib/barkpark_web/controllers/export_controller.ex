defmodule BarkparkWeb.ExportController do
  @moduledoc """
  The backup verb: streams every document in a dataset as NDJSON.

  The response status is committed the moment `send_chunked/2` runs, so a
  failure part-way through can never be re-reported as a status code. That
  makes the honest-outcome rule load-bearing here: when the socket dies
  mid-stream the export must HALT and say, in the log, exactly how far it got
  — never raise, and never fall silent leaving the owner with a truncated
  backup that looks complete.
  """
  use BarkparkWeb, :controller

  require Logger

  alias Barkpark.Content
  alias Barkpark.Repo

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  def export(conn, %{"dataset" => dataset} = params) do
    opts = if(params["type"], do: [type: params["type"]], else: []) ++ scope_opts(conn)

    conn =
      conn
      |> put_resp_content_type("application/x-ndjson")
      |> send_chunked(200)

    # `Content.export_stream/2` is backed by `Repo.stream` (a DB cursor), which
    # Ecto REQUIRES to run inside a transaction — so this wrapper cannot be
    # narrowed away. It stays exactly as wide as it was; the pool-hold that
    # `pds-bl-export-pool-starvation` tracks is untouched by this change and
    # that row is NOT closed by it. What changes is that the transaction now
    # ENDS on a hangup instead of being torn down by a raise.
    {:ok, {conn, delivered, outcome}} =
      Repo.transaction(fn ->
        Content.export_stream(dataset, opts)
        |> Enum.reduce_while({conn, 0, :ok}, fn doc, {acc, delivered, _} ->
          line = Jason.encode!(doc) <> "\n"

          case chunk(acc, line) do
            {:ok, acc} ->
              {:cont, {acc, delivered + 1, :ok}}

            # The client hung up (`:closed`) or the socket errored. Halting
            # closes the cursor and returns the conn Phoenix already owns; a
            # strict match here would instead raise a MatchError inside the
            # open transaction while holding its DB connection.
            {:error, reason} ->
              {:halt, {acc, delivered, {:error, reason}}}
          end
        end)
      end)

    case outcome do
      :ok ->
        conn

      {:error, reason} ->
        Logger.warning(
          "export truncated: client socket closed mid-stream " <>
            "(dataset=#{dataset} type=#{params["type"] || "*"} " <>
            "delivered=#{delivered} reason=#{inspect(reason)}). " <>
            "The 200 was already on the wire — this backup is INCOMPLETE."
        )

        conn
    end
  end
end
