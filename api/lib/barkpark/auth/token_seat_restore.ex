defmodule Barkpark.Auth.TokenSeatRestore do
  @moduledoc """
  Give a live API token back the workspace seats its rotated-out predecessor
  held (task-c6185553d0bd7869, rotation rule task-6f3ccc7dc2be8168). It is the
  HTTP form of the gyl repair: Barkpark Cloud's admin-token rotation before #24619 minted a successor seated in one
  workspace and revoked the old token, so the successor lost the old token's
  other seats. `mix barkpark.token_seat` repairs that from a root shell. This
  module repairs it from `POST /v1/admin/tokens/:id/seats/restore`, which Cloud
  calls with the admin token it holds.

  ## What it may restore

  A seat is restored only when a predecessor of the token held it. A
  predecessor is a token this one replaced through a Cloud admin-token
  rotation (`BarkparkCloud.Registry.AdminTokenRotation`). The box records that
  rotation as two audit rows, and the walk reads only those, never the
  request:

    1. The token's first `token/token_minted` row names the token that minted
       it (`actor_type: "api_token"`).
    2. That minter's first `token/token_revoked` row names the minter itself
       as the actor. The rotation's last step is the old token revoking itself
       through `DELETE /v1/tokens/:id`.
    3. The revoke row comes after the mint row in the audit chain, and the
       minter minted no other token between the two. The rotation mints one
       successor and then revokes, so an older child of the same minter does
       not qualify.
    4. The revoke is at most 10 minutes after the mint. The rotation is one
       Cloud request of five HTTP calls, each bounded at 25 seconds.

  A minter that is live, was revoked by another principal, or revoked itself
  long after the mint is a parent that delegated a narrower token. Its seats
  are not the child's to take. The walk repeats from each predecessor, at most
  8 hops, so a token rotated twice still reaches the seat its first ancestor
  held.

  A revoke row names its actor only from #24224 on. A rotation on an older box
  has a `system` revoke row and gets no predecessor; `mix barkpark.token_seat`
  repairs that case from a root shell.

  Revoking a token keeps its `workspace_memberships` rows, so each
  predecessor's seats are still on the box. The restored role is the role the
  token's own permissions give (`Tenancy.Auth.role_for_permissions/1`) when the
  predecessor administered that workspace, and `member` otherwise. That is the
  rule the rotation's mint uses (`Auth.mint_delegated_token/3` with
  `:also_seat`), so a restore never seats the token above its predecessor.

  A workspace no predecessor held is refused with `not_held_before`. A seat
  whose predecessor was bound to a dataset is refused with `dataset_binding`
  unless the token is bound to the same dataset, and a caller bound to a
  dataset may restore seats only on a token bound to that dataset
  (`Barkpark.Auth.within_dataset_binding?/2`). An apply
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
  # The longest a rotation takes from mint to self-revoke.
  @rotation_window_seconds 600

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

    with {:ok, token} <- live_token(token_id),
         :ok <- caller_within_binding(token, Keyword.get(opts, :actor)) do
      plan = plan(token, slugs)

      cond do
        not apply? -> {:ok, plan}
        plan.refused != [] -> {:error, {:refused, plan}}
        plan.restore == [] -> {:ok, %{plan | applied: true}}
        true -> write(token, plan, Keyword.get(opts, :actor))
      end
    end
  end

  # A dataset-bound caller repairs only tokens bound to the same dataset.
  defp caller_within_binding(token, actor) do
    if Barkpark.Auth.within_dataset_binding?(token, actor),
      do: :ok,
      else: {:error, :dataset_binding}
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

            (from = held_by(held, ws.id)) && not within_predecessor_binding?(token, from) ->
              %{acc | refused: acc.refused ++ [%{workspace: ws.slug, reason: "dataset_binding"}]}

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

  # A seat held by a dataset-bound predecessor goes only to a token bound to
  # the same dataset.
  defp within_predecessor_binding?(token, from_id) do
    Barkpark.Auth.within_dataset_binding?(token, Repo.get(ApiToken, from_id))
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
  The tokens `token_id` replaced through rotation, nearest first. Read from
  the `token_minted` and `token_revoked` audit rows; the first minter that was
  not rotated out ends the walk.
  """
  @spec predecessors(binary()) :: [binary()]
  def predecessors(token_id), do: walk(token_id, [], @max_hops)

  defp walk(_id, acc, 0), do: Enum.reverse(acc)

  defp walk(id, acc, hops) do
    with %Event{actor_id: minter} = mint when is_binary(minter) <- mint_row(id),
         false <- minter in acc or minter == id,
         uuid when is_binary(uuid) <- Repo.uuid_or_nil(minter),
         %ApiToken{revoked_at: %DateTime{}} = parent <- Repo.get(ApiToken, uuid),
         true <- rotated_out?(parent.id, mint) do
      walk(parent.id, [parent.id | acc], hops - 1)
    else
      _ -> Enum.reverse(acc)
    end
  end

  # The audit chain orders by `id`; `occurred_at` is not an order.
  defp mint_row(id) do
    from(e in Event,
      where:
        e.category == "token" and e.action == "token_minted" and e.subject == ^id and
          e.actor_type == "api_token",
      order_by: [asc: e.id],
      limit: 1
    )
    |> Repo.one()
  end

  # `parent` revoked itself after minting the token `mint` records, minted
  # nothing else in between, and did so within the rotation window.
  defp rotated_out?(parent_id, %Event{} = mint) do
    case revoke_row(parent_id) do
      %Event{actor_type: "api_token", actor_id: ^parent_id} = revoke ->
        elapsed = DateTime.diff(revoke.occurred_at, mint.occurred_at, :second)

        revoke.id > mint.id and elapsed in 0..@rotation_window_seconds and
          not minted_between?(parent_id, mint.id, revoke.id)

      _ ->
        false
    end
  end

  # The first revoke row is the one that ended the token. A later row is an
  # idempotent re-revoke and cannot be the token acting on itself.
  defp revoke_row(token_id) do
    from(e in Event,
      where: e.category == "token" and e.action == "token_revoked" and e.subject == ^token_id,
      order_by: [asc: e.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp minted_between?(minter, from_id, to_id) do
    from(e in Event,
      where:
        e.category == "token" and e.action == "token_minted" and e.actor_type == "api_token" and
          e.actor_id == ^minter and e.id > ^from_id and e.id < ^to_id
    )
    |> Repo.exists?()
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
