defmodule BarkparkWeb.Plugs.ResponseWarnings do
  @moduledoc """
  Folds anything queued in `Barkpark.Content.Warnings` into the outgoing 2xx
  JSON body's top-level `warnings` key, via `register_before_send/2`.

  ## Why a hook and not another controller edit

  The `warnings` wire key is already rendered by clients we can no longer
  change. The Go CLI's `emitWarnings` accepts both a bare string and a
  `{code, severity, message}` object, and it is driven from `renderSuccess`
  with an empty `manifest.Command{}` — the rendering is SHAPE-keyed, never
  verb-keyed. Any 2xx JSON body with a top-level `warnings` array is rendered
  by binaries installed months ago.

  Today only three controllers can produce that key, each by hand. This plug
  makes the key producible from ANY point in a request: `Content.Warnings` is
  process-scoped (`Process.put/2`), the emitters run in the same process as the
  controller action, and this hook runs last. A plug or a helper deep in the
  stack queues an advisory; every JSON surface carries it out.

  This module is the CARRIER only. It never produces a warning and it never
  opens the queue — `Warnings.put/3` drops silently unless a collector called
  `Warnings.reset/0` first, and choosing to open the queue is a producer's
  decision, not the carrier's. See "Mounting" below.

  ## What it refuses to touch

  The decision is made from the RESPONSE, never from a roster of surfaces. A
  named skip-list is a registry that rots: the next streaming or download
  controller lands and inherits body corruption silently, and the failure mode
  is a broken image or a broken attachment — which nobody attributes to a
  warnings hook. So the guards are structural and fail closed:

    1. **Empty queue** — one drain, then return the conn untouched. No header
       read, no JSON decode, no body touch. This is the path essentially every
       request takes.
    2. **Status** — only `2xx`. A 4xx/5xx envelope is `Content.Errors`'
       business and passes through untouched.
    3. **`conn.state` must be `:set`** — the body must be a single term at
       before-send time. Plug stamps a DISTINCT state on the conn it hands the
       callbacks: `send_resp/3` gives `:set`, `send_chunked/2` gives
       `:set_chunked`, `send_file/3..5` gives `:set_file` (and nils
       `resp_body`). Matching `:set` excludes both streaming shapes
       structurally; there is nothing there to fold into.
    4. **Content-type must be JSON** — an ALLOWLIST (`application/json`,
       `text/json`, any `*+json` suffix), so an unrecognised or absent
       content-type passes through UNTOUCHED. `application/octet-stream`,
       `text/event-stream`, `image/*` and every type nobody enumerated are
       safe by default.
    5. **Decoded body must be a JSON object** — a top-level array, a scalar,
       or anything that fails to decode has nowhere to put a top-level key, so
       it passes through untouched.

  An existing `warnings` list is APPENDED to, never replaced (so the three
  hand-rolled producers keep their entries); an existing `warnings` value that
  is not a list makes the hook decline entirely rather than reshape a body it
  does not understand.

  `content-length` is dropped when the body is rewritten so the adapter
  recomputes it — a stale length truncates the response.

  ## Mounting

  Not mounted by any pipeline. Mount it in the `:api` (and `:scoped_api`)
  pipelines, LAST, once a producer exists — being last is what makes it see
  the fully-built body, and `register_before_send` callbacks run in reverse
  registration order, so a later-registered hook runs earlier.
  """

  @behaviour Plug

  import Plug.Conn

  alias Barkpark.Content.Warnings

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: register_before_send(conn, &fold/1)

  # Public for the mutation/unit tests: the whole decision is in here, and it
  # is exercised directly as well as through a real send.
  @doc false
  def fold(%Plug.Conn{} = conn) do
    case Warnings.drain() do
      [] -> conn
      entries -> attach(conn, entries)
    end
  end

  defp attach(%Plug.Conn{state: :set, status: status} = conn, entries)
       when is_integer(status) and status >= 200 and status < 300 do
    if json_response?(conn), do: rewrite(conn, entries), else: conn
  end

  defp attach(conn, _entries), do: conn

  defp rewrite(conn, entries) do
    with body when is_binary(body) <- safe_body(conn.resp_body),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body),
         {:ok, merged} <- merge(decoded, entries),
         {:ok, json} <- Jason.encode(merged) do
      conn
      |> delete_resp_header("content-length")
      |> then(&%{&1 | resp_body: json})
    else
      _ -> conn
    end
  end

  defp safe_body(nil), do: nil
  defp safe_body(body) when is_binary(body), do: body
  defp safe_body(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp safe_body(_), do: nil

  defp merge(decoded, entries) do
    case Map.fetch(decoded, "warnings") do
      :error ->
        {:ok, Map.put(decoded, "warnings", entries)}

      {:ok, existing} when is_list(existing) ->
        {:ok, Map.put(decoded, "warnings", existing ++ entries)}

      {:ok, _other} ->
        :decline
    end
  end

  defp json_response?(conn) do
    case get_resp_header(conn, "content-type") do
      [value | _] -> json_content_type?(value)
      [] -> false
    end
  end

  defp json_content_type?(value) do
    value
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
    |> json_mime?()
  end

  defp json_mime?("application/json"), do: true
  defp json_mime?("text/json"), do: true
  defp json_mime?(mime), do: String.ends_with?(mime, "+json")
end
