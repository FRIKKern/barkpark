defmodule Barkpark.EcosystemPanel do
  @moduledoc """
  The ecosystem panel snapshot store (task-270112c682dc71de, plan Paper
  `ecosystem-panel-behind-login`).

  The Mac mini builds the eco-dash panel every 15 minutes and pushes the HTML
  here. Each workspace keeps ONE row (`ecosystem_panel_snapshots`), overwritten
  in place by every push, so nothing grows and no revision is kept.

  ## Scope

  Every function takes the workspace id the CALLER has already resolved and
  authorised: the upload controller passes the id of the URL workspace that
  `ResolveWorkspace` resolved and `RequireWorkspaceRole` gated. Nothing here
  reads a workspace id from a request body or query. There is no list
  function and no read across workspaces.

  ## What travels where

    * `put/4` writes the row and broadcasts only `{:ecosystem_panel_snapshot,
      %{sha256: sha}}` on `topic/1`. The HTML never rides PubSub.
    * `get/1` returns the row for one workspace, or `nil`.
    * `get_stamp/1` returns only its `built_at` and `sha256` (the shell).

  ## Limits

    * HTML over `max_bytes/0` (2 MB) → `{:error, :too_large}`.
    * `built_at` more than `max_future_seconds/0` (10 minutes) ahead of the
      server clock → `{:error, :built_at_in_future}`. The age line the panel
      shows is drawn from `built_at`, so a Mac with a fast clock cannot keep a
      stale page looking fresh.

  This is a core module (it reads the table with no plugin gate), so the table
  is core-owned in `Barkpark.SchemaOwnership`. The routes that reach it belong
  to the `Barkpark.Plugins.EcosystemPanel` plugin.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.EcosystemPanel.Snapshot
  alias Barkpark.Repo

  @max_bytes 2 * 1024 * 1024
  @max_future_seconds 10 * 60
  @replace [:html, :built_at, :received_at, :bytes, :sha256]

  @doc "The largest HTML body a push may carry, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "How far ahead of the server clock `built_at` may be, in seconds."
  @spec max_future_seconds() :: pos_integer()
  def max_future_seconds, do: @max_future_seconds

  @doc "The PubSub topic for one workspace's snapshot changes. Carries the sha256 only."
  @spec topic(binary()) :: String.t()
  def topic(workspace_id) when is_binary(workspace_id), do: "ecosystem_panel:" <> workspace_id

  @doc """
  Write (or overwrite) the snapshot for `workspace_id`.

  `opts[:now]` overrides the server clock (tests). Returns the stored row.
  """
  @spec put(binary(), binary(), DateTime.t(), keyword()) ::
          {:ok, Snapshot.t()}
          | {:error, :too_large | :built_at_in_future | :invalid}
  def put(workspace_id, html, %DateTime{} = built_at, opts \\ [])
      when is_binary(workspace_id) and is_binary(html) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    cond do
      byte_size(html) > @max_bytes ->
        {:error, :too_large}

      DateTime.diff(built_at, now, :second) > @max_future_seconds ->
        {:error, :built_at_in_future}

      true ->
        upsert(workspace_id, html, built_at, now)
    end
  end

  @doc "The snapshot for `workspace_id`, or `nil`. A malformed id is `nil`, never a raise."
  @spec get(term()) :: Snapshot.t() | nil
  def get(workspace_id) do
    case Ecto.UUID.cast(workspace_id) do
      {:ok, id} -> Repo.get(Snapshot, id)
      :error -> nil
    end
  end

  @doc """
  The `built_at` and `sha256` of `workspace_id`'s snapshot, without the HTML,
  or `nil`. The shell's age line and iframe src need only these two.
  """
  @spec get_stamp(term()) :: %{built_at: DateTime.t(), sha256: String.t()} | nil
  def get_stamp(workspace_id) do
    case Ecto.UUID.cast(workspace_id) do
      {:ok, id} ->
        Repo.one(
          from s in Snapshot,
            where: s.workspace_id == ^id,
            select: %{built_at: s.built_at, sha256: s.sha256}
        )

      :error ->
        nil
    end
  end

  defp upsert(workspace_id, html, built_at, now) do
    with {:ok, id} <- Ecto.UUID.cast(workspace_id),
         {:ok, row} <- insert(id, html, built_at, now) do
      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        topic(id),
        {:ecosystem_panel_snapshot, %{sha256: row.sha256}}
      )

      {:ok, row}
    else
      _ -> {:error, :invalid}
    end
  end

  defp insert(id, html, built_at, now) do
    attrs = %{
      html: html,
      built_at: built_at,
      received_at: now,
      bytes: byte_size(html),
      sha256: :crypto.hash(:sha256, html) |> Base.encode16(case: :lower)
    }

    %Snapshot{workspace_id: id}
    |> Ecto.Changeset.cast(attrs, Map.keys(attrs))
    |> Ecto.Changeset.validate_required(Map.keys(attrs))
    |> Ecto.Changeset.foreign_key_constraint(:workspace_id,
      name: :ecosystem_panel_snapshots_workspace_id_fkey
    )
    |> Repo.insert(on_conflict: {:replace, @replace}, conflict_target: :workspace_id)
  end
end
