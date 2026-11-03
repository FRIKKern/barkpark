defmodule Barkpark.Auth.TokenSeatRestore do
  @moduledoc """
  Give a live API token back the workspace seats its revoked predecessor held
  (task-c6185553d0bd7869). It is the HTTP form of the gyl repair: Barkpark
  Cloud's admin-token rotation before #24619 minted a successor seated in one
  workspace and revoked the old token, so the successor lost the old token's
  other seats. `mix barkpark.token_seat` repairs that from a root shell. This
  module repairs it from `POST /v1/admin/tokens/:id/seats/restore`, which Cloud
  calls with the admin token it holds.

  ## What it may restore

  A seat is restored only when a predecessor of the token held it. The
  predecessors are found from the box's own records, never from the request:

    1. The token's `token/token_minted` audit row names the token that minted
       it (`actor_type: "api_token"`).
    2. That minter counts as a predecessor only when it is revoked. A minter
       that is still live is a parent that delegated a narrower token, not a
       rotated-away token, and its seats are not the child's to take.
    3. The walk repeats from the predecessor, at most 8 hops, so a token
       rotated twice still reaches the seat its first ancestor held.

  Revoking a token keeps its `workspace_memberships` rows, so each
  predecessor's seats are still on the box. The restored role is the role the
  token's own permissions give (`Tenancy.Auth.role_for_permissions/1`) when the
  predecessor administered that workspace, and `member` otherwise. That is the
  rule the rotation's mint uses (`Auth.mint_delegated_token/3` with
  `:also_seat`), so a restore never seats the token above its predecessor.

  A workspace no predecessor held is refused with `not_held_before`. An apply
  writes nothing unless every requested workspace is restorable or already
  seated. Each new seat and a `token/token_seated` audit row naming the caller
  and the predecessor commit in one transaction.

  With no workspaces named, the plan covers every seat a predecessor held.
  """

  import Ecto.Query, warn: false

  alias Barkpark.{Audit, Repo, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  @max_hops 8

  @type seat :: %{workspace: String.t(), role: String.t(), from_token: binary()}
  @type refusal :: %{workspace: String.t(), reason: String.t()}
  @type plan :: %{
          token_id: binary(),
          predecessors: [binary()],
          restore: [seat()],
          already: [String.t()],
          refused: [refusal()],
          applied: boolean()
        }

  @doc """
  Plan, and with `apply: true` write, the seats `token_id` gets back.
  `slugs` names the workspaces; `[]` means every seat a predecessor held.
  `:actor` is the calling `%ApiToken{}`, named on each audit row.

  Returns `{:ok, plan}`, `{:error, {:refused, plan}}` when an apply names a
  workspace that cannot be restored, `{:error, :token_not_found}`,
  `{:error, :token_not_live}`, or a write error.
  """
  @spec restore(binary(), [String.t()], keyword()) ::
          {:ok, plan()} | {:error, term()}
  def restore(token_id, slugs, opts \\ []) when is_binary(token_id) and is_list(slugs) do
    apply? = Keyword.get(opts, :apply, false) == true

    with {:ok, token} <- live_token(token_id) do
      plan = plan(token, slugs)

      cond do
        not apply? -> {:ok, plan}
        plan.refused != [] -> {:error, {:refused, plan}}
        plan.restore == [] -> {:ok, %{plan | applied: true}}
        true -> write(token, plan, Keyword.get(opts, :actor))
      end
    end
  end

  defp live_token(token_id) do
    now = DateTime.utc_now()

    with uuid when is_binary(uuid) <- Repo.uuid_or_nil(token_id),
         %ApiToken{} = token <- Repo.get(ApiToken, uuid) do
      live? =
        token.kind == "api" and is_nil(token.revoked_at) and
          (is_nil(token.expires_at) or DateTime.compare(token.expires_at, now) == :gt)

      if live?, do: {:ok, token}, else: {:error, :token_not_live}
    else
      _ -> {:error, :token_not_found}
    end
  end

  # ── the plan ──────────────────────────────────────────────────────────────

  defp plan(%ApiToken{} = token, slugs) do
    predecessors = predecessors(token.id)
    held = held_seats(predecessors)
    role = TenancyAuth.role_for_permissions(token.permissions || [])

    wanted =
      case clean(slugs) do
        [] -> held |> Enum.map(fn {ws, _from} -> ws end) |> Enum.uniq_by(& &1.id)
        named -> Enum.map(named, &(Tenancy.get_workspace_by_slug(&1) || {:unknown, &1}))
      end

    Enum.reduce(
      wanted,
      %{
        token_id: token.id,
        predecessors: predecessors,
        restore: [],
        already: [],
        refused: [],
        applied: false
      },
      fn
        {:unknown, slug}, acc ->
          %{acc | refused: acc.refused ++ [%{workspace: slug, reason: "unknown_workspace"}]}

        ws, acc ->
          cond do
            TenancyAuth.membership_role(token.id, ws.id) != nil ->
              %{acc | already: acc.already ++ [ws.slug]}

            from = held_by(held, ws.id) ->
              seat_role = if TenancyAuth.workspace_admin?(from, ws.id), do: role, else: "member"
              seat = %{workspace: ws.slug, workspace_id: ws.id, role: seat_role, from_token: from}
              %{acc | restore: acc.restore ++ [seat]}

            true ->
              %{acc | refused: acc.refused ++ [%{workspace: ws.slug, reason: "not_held_before"}]}
          end
      end
    )
  end

  defp clean(slugs) do
    slugs
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # The nearest predecessor that held the workspace.
  defp held_by(held, ws_id) do
    Enum.find_value(held, fn {ws, from} -> if ws.id == ws_id, do: from end)
  end

  # `[{%Workspace{}, predecessor_id}]`, nearest predecessor first.
  defp held_seats(predecessors) do
    Enum.flat_map(predecessors, fn pid ->
      from(m in Membership,
        join: w in assoc(m, :workspace),
        where: m.principal_type == "api_token" and m.principal_id == ^pid,
        order_by: w.slug,
        select: w
      )
      |> Repo.all()
      |> Enum.map(&{&1, pid})
    end)
  end

  @doc """
  The revoked tokens `token_id` descends from, nearest first. Read from the
  `token_minted` audit rows; a live minter ends the walk.
  """
  @spec predecessors(binary()) :: [binary()]
  def predecessors(token_id), do: walk(token_id, [], @max_hops)

  defp walk(_id, acc, 0), do: Enum.reverse(acc)

  defp walk(id, acc, hops) do
    with minter when is_binary(minter) <- minter_of(id),
         false <- minter in acc or minter == id,
         uuid when is_binary(uuid) <- Repo.uuid_or_nil(minter),
         %ApiToken{revoked_at: %DateTime{}} = parent <- Repo.get(ApiToken, uuid) do
      walk(parent.id, [parent.id | acc], hops - 1)
    else
      _ -> Enum.reverse(acc)
    end
  end

  defp minter_of(id) do
    from(e in Event,
      where:
        e.category == "token" and e.action == "token_minted" and e.subject == ^id and
          e.actor_type == "api_token",
      order_by: [asc: e.occurred_at],
      limit: 1,
      select: e.actor_id
    )
    |> Repo.one()
  end

  # ── the write ─────────────────────────────────────────────────────────────

  defp write(token, plan, actor) do
    Repo.transaction(fn ->
      Enum.each(plan.restore, fn seat ->
        with {:ok, _} <-
               TenancyAuth.create_membership(seat.workspace_id, token.id, seat.role, "api_token"),
             {:ok, _} <- audit(token, seat, actor) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
    |> case do
      {:ok, _} ->
        Enum.each(plan.restore, &Barkpark.Tenancy.Members.announce_seats_changed(&1.workspace_id))
        {:ok, %{plan | applied: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp audit(token, seat, actor) do
    {actor_type, actor_id} =
      case actor do
        %ApiToken{id: id} -> {"api_token", id}
        _ -> {"system", "seat restore"}
      end

    Audit.emit(%{
      category: "token",
      action: "token_seated",
      subject: token.id,
      actor_type: actor_type,
      actor_id: actor_id,
      workspace_id: seat.workspace_id,
      metadata: %{
        "via" => "seat restore (POST /v1/admin/tokens/:id/seats/restore)",
        "label" => token.label,
        "role" => seat.role,
        "restored_from" => seat.from_token
      }
    })
  end

  @doc "The plan as JSON: slugs, roles and token ids only."
  @spec to_json(plan()) :: map()
  def to_json(plan) do
    %{
      token_id: plan.token_id,
      predecessors: plan.predecessors,
      restore: Enum.map(plan.restore, &Map.take(&1, [:workspace, :role, :from_token])),
      already: plan.already,
      refused: plan.refused,
      applied: plan.applied
    }
  end
end
