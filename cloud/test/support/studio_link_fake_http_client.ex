defmodule BarkparkCloud.StudioLinkFakeHttpClient do
  @moduledoc """
  Test double for the instance-API transport seam (`:studio_link_http_client`) —
  the studio-link login-ticket call AND the C11 usage fan-out
  (`build_usage/2` in the router). Wired in via `config/test.exs`.

  ## Why this is an owner-keyed SHARED store, not a process dictionary

  The original design stashed the response queue + request log in the CALLING
  process's dictionary. That is correct only while every call happens in ONE
  process. The C11 usage fan-out (`sum_across_datasets/3`) runs the per-dataset
  documents + webhooks calls CONCURRENTLY in `Task.async_stream` CHILD processes;
  those children have their OWN (empty) dictionary, so a process-dict fake would
  serve them the empty-queue default and record their requests where the test
  process can never see them — making token-custody / URL asserts vacuously green
  and real cross-dataset sums impossible to prove.

  So the store lives in ONE long-lived Agent, keyed by the OWNER pid (the process
  that called `program/1`). A child looks its owner up by walking `$callers` — the
  ancestry `Task`/`Task.async_stream` propagate automatically (the same mechanism
  the `DataCase` sandbox drain relies on). Result: a fan-out request made off the
  test process is served the RIGHT programmed body and recorded where
  `requests/0` (called on the test process) can see it.

  Isolation across `async: true` tests is by pid: each test programs under its own
  pid, and only its own pid appears in its callers chain, so nothing bleeds.

  ## Two programming shapes

    * `program(list)` — a FIFO queue (the studio-link / self-update / site-url /
      autoupdate-worker callers, all single-process, sequential). Empty queue →
      the default 201 login-ticket. This is the ORIGINAL contract, unchanged.

    * `program(map)` — PATH-KEYED responses (the usage fan-out): the request URL's
      path (then `"path?query"`, then bare `"path"`) selects the response, so
      concurrent out-of-order children each get the right body regardless of
      arrival order. Prior art: `HetznerFakeHttpClient.program/1`. An unprogrammed
      path defaults to an empty `{:ok, 200, "{}"}`.

  A programmed response may be wrapped `{:delay, ms, response}` to simulate a slow
  upstream: the fake sleeps `ms` (in the CALLING process, never inside the Agent)
  before returning `response` — this is what the aggregate-deadline test drives.

  Usage:

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 201, body: ~s({"ticket":"bplt_x","expires_in":60})}}
      ])

      StudioLinkFakeHttpClient.program(%{
        "/api/workspaces/default/projects/default/datasets" =>
          {:ok, %{status: 200, body: ~s({"datasets":[{"slug":"production"}]})}},
        "/v1/data/analytics/production" =>
          {:ok, %{status: 200, body: ~s({"total_documents":137})}}
      })
  """

  @store __MODULE__.Store

  @fifo_default {:ok, %{status: 201, body: ~s({"ticket":"bplt_default-ticket","expires_in":60})}}
  @paths_default {:ok, %{status: 200, body: "{}"}}

  @doc """
  Program the responses `request/1` will return, keyed by owner (the calling pid).
  A LIST is a FIFO queue (original contract); a MAP is path-keyed. Resets this
  owner's request log.
  """
  def program(responses) when is_list(responses), do: put_entry(:fifo, responses)
  def program(responses) when is_map(responses), do: put_entry(:paths, responses)

  @doc "The requests THIS owner has seen so far, in call order — including ones made in Task children."
  def requests do
    ensure_started()
    me = self()

    Agent.get(@store, fn state ->
      case Map.get(state, me) do
        %{requests: reqs} -> Enum.reverse(reqs)
        _ -> []
      end
    end)
  end

  @doc "The HttpClient contract: record the request under its owner, return the owner's next programmed response."
  def request(req) do
    ensure_started()
    # Computed on the CALLING process — `$callers` is the ancestry Task propagates.
    callers = [self() | Process.get(:"$callers", [])]

    resp =
      Agent.get_and_update(@store, fn state ->
        owner = Enum.find(callers, hd(callers), &Map.has_key?(state, &1))
        entry = Map.get(state, owner, %{mode: :fifo, responses: [], requests: []})
        {resp, entry} = resolve_response(entry, req)
        {resp, Map.put(state, owner, %{entry | requests: [req | entry.requests]})}
      end)

    # Sleep (if any) OUTSIDE the Agent so a slow upstream never serializes others.
    case resp do
      {:delay, ms, actual} ->
        Process.sleep(ms)
        actual

      other ->
        other
    end
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp put_entry(mode, responses) do
    ensure_started()
    me = self()
    Agent.update(@store, &Map.put(&1, me, %{mode: mode, responses: responses, requests: []}))
    :ok
  end

  # FIFO: pop the head, default when drained.
  defp resolve_response(%{mode: :fifo, responses: [next | rest]} = entry, _req),
    do: {next, %{entry | responses: rest}}

  defp resolve_response(%{mode: :fifo, responses: []} = entry, _req),
    do: {@fifo_default, entry}

  # Path-keyed: look the URL's path up (never consumes — concurrent children read).
  defp resolve_response(%{mode: :paths, responses: map} = entry, %{url: url}) do
    %URI{path: path, query: query} = URI.parse(url)

    resp =
      with :error <- Map.fetch(map, path_with_query(path, query)),
           :error <- Map.fetch(map, path) do
        @paths_default
      else
        {:ok, r} -> r
      end

    {resp, entry}
  end

  defp resolve_response(%{mode: :paths} = entry, _req), do: {@paths_default, entry}

  defp path_with_query(path, nil), do: path
  defp path_with_query(path, query), do: path <> "?" <> query

  # One long-lived, UNLINKED Agent owns the store for the whole test run — an
  # unlinked start so it outlives the test process that first touched it (a linked
  # Agent would die with that test and vanish for concurrent async tests). Lazy +
  # race-safe: a concurrent starter that loses just sees `:already_started`.
  defp ensure_started do
    case Process.whereis(@store) do
      nil ->
        case Agent.start(fn -> %{} end, name: @store) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
