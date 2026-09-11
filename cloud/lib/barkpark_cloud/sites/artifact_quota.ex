defmodule BarkparkCloud.Sites.ArtifactQuota do
  @moduledoc """
  ssw9-bl-artifact-retention-quota — the per-TEAM ceiling on stored artifact
  bytes.

  ## What was unbounded

  The upload route's only limit was `@max_artifact_bytes` (32 MB), and that is
  PER REQUEST. Nothing counted a team's rows, so a caller holding a write PAT
  could mint a prebuilt deployment and upload 32 MB, over and over, and the only
  thing standing between that loop and a full `cloud_pgdata` was the deploy
  driver eventually settling each row. Abandon the row instead of driving it and
  even that stopped applying. An unbounded disk-fill primitive on an
  authenticated route is still a disk-fill primitive.

  ## The accounting

  Live bytes only — `sum(site_artifacts.byte_size)` for the sites a team owns.
  It is deliberately NOT a lifetime counter: `Sites.ArtifactReaper` and the
  driver's `drop_artifact/1` both delete rows, and a quota that did not fall when
  bytes were freed would refuse a team that is holding nothing.

  ## The refusal

  Typed, so a caller can branch on it and a route can name the numbers:

      {:error, {:artifact_quota_exceeded, %{used_bytes: u, limit_bytes: l, requested_bytes: r}}}

  The comparison is `used + requested > limit` — checked against the bytes the
  control plane ACTUALLY received, so a client cannot under-declare its way past
  the ceiling with a header.

  ## The knob

  `config :barkpark_cloud, :artifact_quota_bytes`, ops-tunable through
  `ARTIFACT_QUOTA_BYTES`. The default is 512 MB — sixteen max-sized artifacts in
  flight at once, which is far above any real team's concurrent prebuilt deploys
  and far below "the control plane's only durable volume".

  Setting it to `:infinity` disables the ceiling; that is an explicit operator
  choice, never a default.
  """

  alias BarkparkCloud.Sites.ArtifactReaper

  @default_quota_bytes 512 * 1024 * 1024

  @typedoc "What a refusal carries: enough for a route to write the sentence."
  @type refusal :: %{
          used_bytes: non_neg_integer(),
          limit_bytes: pos_integer(),
          requested_bytes: non_neg_integer()
        }

  @doc "The configured per-team ceiling in bytes, or `:infinity`."
  @spec limit_bytes() :: pos_integer() | :infinity
  def limit_bytes do
    Application.get_env(:barkpark_cloud, :artifact_quota_bytes, @default_quota_bytes)
  end

  @doc "The bytes this team currently holds in `site_artifacts`."
  @spec used_bytes(binary()) :: non_neg_integer()
  def used_bytes(team_id) when is_binary(team_id), do: ArtifactReaper.usage(team_id).bytes

  @doc """
  May `team_id` store `requested_bytes` more?

  `:ok`, or `{:error, {:artifact_quota_exceeded, refusal}}`. Boundary: exactly AT
  the limit is allowed; one byte past it is refused.
  """
  @spec check(binary(), non_neg_integer()) :: :ok | {:error, {:artifact_quota_exceeded, refusal()}}
  def check(team_id, requested_bytes)
      when is_binary(team_id) and is_integer(requested_bytes) and requested_bytes >= 0 do
    case limit_bytes() do
      :infinity ->
        :ok

      limit when is_integer(limit) ->
        used = used_bytes(team_id)

        if used + requested_bytes > limit do
          {:error,
           {:artifact_quota_exceeded,
            %{used_bytes: used, limit_bytes: limit, requested_bytes: requested_bytes}}}
        else
          :ok
        end
    end
  end
end
