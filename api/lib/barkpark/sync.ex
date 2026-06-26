defmodule Barkpark.Sync do
  @moduledoc """
  One-way PULL sync (Phase 1).

  A supervised `Barkpark.Sync.Worker` opens a streaming `GET` to a REMOTE
  Barkpark's `/v1/data/listen/:dataset` SSE endpoint (resuming from the stored
  cursor via `Last-Event-ID`), parses frames through the pure
  `Barkpark.Sync.SSE` seam, and applies each mutation envelope into the LOCAL
  workspace through `Barkpark.Sync.Applier` — which uses Content's PUBLIC API
  only. Nothing in this subsystem touches `content.ex` or `tasks.ex`.

  The whole thing is config-gated and DORMANT when the `BARKPARK_SYNC_*` env
  vars are absent (the fresh-install invariant), mirroring the Indx/Bokbasen
  precedent. `application.ex` calls `enabled?/0` to decide whether to splice the
  Worker (and its dedicated Finch pool) into the supervision tree.

  This module is the thin facade; `SSE`, `Applier`, `Cursor`, `Settings`, and
  `Worker` are the implementation and are not part of the external API.
  """

  alias Barkpark.Sync.{Applier, SSE, Settings}
  alias Barkpark.Tenancy

  @doc "True when a sync source is fully configured and enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: config().enabled

  @doc """
  True when push is active: the source is enabled (the pull gate) AND the
  separate `push_enabled` flag is set. `application.ex` calls this to decide
  whether to splice `Barkpark.Sync.PushWorker`. PUSH can be off while PULL is on.
  """
  @spec push_active?() :: boolean()
  def push_active?, do: Settings.push_active?(config())

  @doc "Resolved settings (single source of truth) from Application env."
  @spec config() :: Settings.t()
  def config, do: Settings.load()

  @doc """
  Build the `Pusher` context from resolved `settings`: the cursor `source`, the
  `dataset` string, and the remote `url`/`token` the default transport posts to.
  No write scope is needed (push READS local events and POSTs to the remote).
  """
  @spec push_context(Settings.t()) :: Barkpark.Sync.Pusher.ctx()
  def push_context(%Settings{
        source: source,
        dataset: dataset,
        url: url,
        token: token,
        workspace: workspace,
        project: project
      }) do
    # workspace/project ride the ctx so the push transport addresses the SCOPED
    # /w/<ws>/p/<proj> remote path — NOT the flat (Default-workspace) endpoint.
    %{
      source: source,
      dataset: dataset,
      url: url,
      token: token,
      workspace: workspace,
      project: project
    }
  end

  @doc """
  Drain one accumulated SSE buffer: parse complete frames and apply each event
  into the local workspace, returning `{results, rest}` where `rest` is the
  incomplete remainder to carry into the next chunk. THE deterministic
  parse+apply+dedup+cursor seam — used by both the streaming `Worker` and the
  tests (fed raw frame bytes, no network).

  Drains in order and **HALTS at the first `{:error, _}`** — it does NOT apply
  the events that follow a failed one. This is load-bearing: the cursor is a
  single monotonic high-water mark, so applying a later event after an earlier
  failure would advance the cursor past the gap and the producer's
  `id > since` replay would never re-deliver the failed event (silent loss).
  Halting leaves the cursor at the last success; the `Worker` reconnects and
  the producer replays from the failed event. Events after the halt are dropped
  from this buffer and re-arrive on reconnect.
  """
  @spec apply_frames(binary(), Applier.ctx()) ::
          {[
             {non_neg_integer() | nil,
              {:ok, :applied | :skipped | :dead_lettered} | {:error, term()}}
           ], binary()}
  def apply_frames(buffer, ctx) when is_binary(buffer) do
    {events, rest} = SSE.parse_frames(buffer)

    results =
      events
      |> Enum.reduce_while([], fn ev, acc ->
        result = Applier.apply_event(ev, ctx)
        acc = [{ev.id, result} | acc]

        case result do
          {:error, _} -> {:halt, acc}
          _ -> {:cont, acc}
        end
      end)
      |> Enum.reverse()

    {results, rest}
  end

  @doc """
  Build the `Applier` context from resolved `settings`: the cursor source, the
  dataset string, and the LOCAL write scope resolved from the configured
  workspace slug (`[workspace_id:, project_id:]`).

  When a workspace slug is configured but does NOT resolve to a real workspace,
  the scope is the `:unresolved` sentinel — the `Applier` then refuses to write
  (rather than degrade to a NULL/global write, which the tenancy invariant in
  `api/CLAUDE.md` forbids: NULL-scope rows are invisible). `enabled?/0` already
  requires a workspace, so the no-slug clause is unreachable for the live
  Worker; it stays `[]` only for direct/test callers.
  """
  @spec context(Settings.t()) :: Applier.ctx()
  def context(%Settings{source: source, dataset: dataset} = settings) do
    %{
      source: source,
      dataset: dataset,
      scope: resolve_scope(settings),
      max_attempts: settings.max_attempts
    }
  end

  defp resolve_scope(%Settings{workspace: slug}) when is_binary(slug) do
    case Tenancy.get_workspace_by_slug(slug) do
      %{id: ws_id} ->
        project_id =
          case Tenancy.get_project(slug, "default") do
            %{id: pid} -> pid
            _ -> nil
          end

        [workspace_id: ws_id, project_id: project_id]

      _ ->
        :unresolved
    end
  end

  defp resolve_scope(_settings), do: []
end
