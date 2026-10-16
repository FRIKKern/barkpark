defmodule Barkpark.StudioChat.ApplicationTurns do
  @moduledoc """
  Durable personal application turns in the existing chat store. A login accepts
  raw input; a separately authenticated bound host commits application state.
  This module never starts a provider, enqueues repository work or grants source
  permission. State is versioned application data, not verified semantic truth.
  """
  import Ecto.Query
  alias Barkpark.{Accounts, Repo, StudioChat, Tenancy}
  alias Barkpark.Accounts.{User, UserSession}
  alias Barkpark.ChatHosts.{ExecutionLease, RegisteredHost}
  alias Barkpark.StudioChat.{ApplicationBinding, Message, Session}
  alias Barkpark.Tenancy.Membership

  @ttl 120
  @max_revision 2_147_483_646

  def create({:personal, ws, user} = scope, login, app, attrs) when is_map(attrs) do
    transaction(fn ->
      actor!(ws, user, login)
      binding = binding!(app, ws)
      host!(binding["host_id"], ws)

      unless Map.keys(attrs) -- ["title"] == [] and
               (not Map.has_key?(attrs, "title") or text?(attrs["title"], 256)),
             do: fail(:invalid_request)

      {:ok, session} =
        StudioChat.create_session(
          %{id: Ecto.UUID.generate(), title: Map.get(attrs, "title", "New chat"), mode: "plan"},
          scope
        )

      state = %{
        "binding" => binding,
        "revision" => 0,
        "context" => %{},
        "selection" => [],
        "source_identities" => [],
        "last_turn_id" => nil
      }

      session |> Ecto.Changeset.change(application_state: state) |> Repo.update!()
    end)
  end

  def create(_, _, _, _), do: {:error, :forbidden}

  def read(scope, login, id) do
    transaction(fn ->
      session = personal!(scope, login, id)
      state = state!(session)

      latest =
        Repo.one(
          from l in ExecutionLease,
            where: l.session_id == ^id and l.provider == "application",
            order_by: [desc: l.inserted_at, desc: l.id],
            limit: 1,
            lock: "FOR UPDATE"
        )

      latest = if latest, do: expire!(latest), else: nil

      %{
        id: session.id,
        revision: state["revision"],
        context: state["context"],
        selection: state["selection"],
        source_identities: state["source_identities"],
        last_turn_id: state["last_turn_id"],
        contract_version: state["binding"]["contract_version"],
        latest_turn: if(latest, do: accepted(latest), else: nil),
        last_answer: last_answer(session.id, state)
      }
    end)
  end

  def accept(scope, login, id, attrs) when is_map(attrs) do
    transaction(fn ->
      session = personal!(scope, login, id)
      state = state!(session)
      validate_request!(attrs)
      digest = digest(attrs)
      key = "application:" <> session.id <> ":" <> attrs["request_id"]

      existing =
        Repo.one(
          from l in ExecutionLease,
            where: l.host_id == ^state["binding"]["host_id"] and l.command_key == ^key,
            lock: "FOR UPDATE"
        )

      if existing do
        unless existing.application_turn["request_digest"] == digest, do: fail(:conflict)

        existing |> expire!() |> accepted()
      else
        unless state["revision"] == attrs["expected_revision"] and
                 state["revision"] < @max_revision,
               do: fail(:conflict)

        pending =
          Repo.all(
            from l in ExecutionLease,
              where:
                l.session_id == ^id and l.provider == "application" and
                  l.status in ["leased", "running", "disconnected"],
              lock: "FOR UPDATE"
          )

        now = DateTime.utc_now()

        Enum.each(pending, fn lease ->
          if not expired?(lease, now) and is_nil(lease.revoked_at),
            do: fail(:turn_in_progress)

          cancel_lease!(lease, "expired")
        end)

        host!(state["binding"]["host_id"], session.owner_workspace_id)
        turn_id = Ecto.UUID.generate()
        deadline = DateTime.add(now, @ttl)

        turn = %{
          "id" => turn_id,
          "query" => attrs["query"],
          "request_id" => attrs["request_id"],
          "request_digest" => digest,
          "base_revision" => state["revision"],
          "actor_user_id" => session.owner_user_id,
          "actor_session_id" => login,
          "binding" => state["binding"],
          "deadline" => DateTime.to_iso8601(deadline),
          "status" => "accepted"
        }

        lease =
          Repo.insert!(%ExecutionLease{
            id: turn_id,
            host_id: state["binding"]["host_id"],
            workspace_id: session.owner_workspace_id,
            session_id: session.id,
            provider: "application",
            command_key: key,
            expires_at: deadline,
            application_turn: turn
          })

        {:ok, _} =
          StudioChat.append_message(session.id, %{
            role: "user",
            source_markdown: attrs["query"],
            metadata: %{"application_turn_id" => turn_id}
          })

        accepted(lease)
      end
    end)
  end

  def accept(_, _, _, _), do: {:error, :invalid_request}

  def fetch(%RegisteredHost{} = host, turn_id) do
    transaction(fn ->
      {session, lease, state} = machine!(host, turn_id)
      live!(lease)
      unless state["revision"] == lease.application_turn["base_revision"], do: fail(:conflict)

      Map.merge(accepted(lease), %{
        session_id: session.id,
        actor_user_id: session.owner_user_id,
        workspace_id: session.owner_workspace_id,
        query: lease.application_turn["query"],
        contract_version: state["binding"]["contract_version"],
        context: state["context"],
        selection: state["selection"],
        source_identities: state["source_identities"]
      })
    end)
  end

  def fetch(_, _), do: {:error, :forbidden}

  def commit(%RegisteredHost{} = host, turn_id, attrs) when is_map(attrs) do
    transaction(fn ->
      {session, lease, state} = machine!(host, turn_id)
      validate_commit!(attrs, state)
      turn = lease.application_turn

      unless attrs["epoch"] == lease.epoch and attrs["request_digest"] == turn["request_digest"] and
               attrs["expected_revision"] == turn["base_revision"],
             do: fail(:conflict)

      hash = digest(attrs)

      if turn["status"] == "committed" do
        unless turn["result_digest"] == hash, do: fail(:conflict)
        commit_receipt(lease)
      else
        live!(lease)
        unless state["revision"] == turn["base_revision"], do: fail(:conflict)
        result = attrs["result"]
        revision = state["revision"] + 1

        next =
          Map.merge(state, Map.take(result, ~w(context selection source_identities)))
          |> Map.merge(%{"revision" => revision, "last_turn_id" => turn_id})

        metadata = %{
          "application" => %{
            "turn_id" => turn_id,
            "revision" => revision,
            "contract_version" => result["contract_version"],
            "answer" => result["answer"],
            "selection" => result["selection"],
            "source_identities" => result["source_identities"]
          }
        }

        {:ok, message} =
          StudioChat.append_message(session.id, %{
            role: "assistant",
            source_markdown: result["answer"]["text"],
            metadata: metadata
          })

        session |> Ecto.Changeset.change(application_state: next) |> Repo.update!()

        turn =
          Map.merge(turn, %{
            "status" => "committed",
            "result_digest" => hash,
            "committed_revision" => revision,
            "message_id" => message.id
          })

        lease =
          lease
          |> Ecto.Changeset.change(status: "completed", application_turn: turn)
          |> Repo.update!()

        commit_receipt(lease)
      end
    end)
  end

  def commit(_, _, _), do: {:error, :invalid_request}

  def cancel(scope, login, id, turn_id) do
    transaction(fn ->
      session = personal!(scope, login, id)
      _ = state!(session)
      lease = lease!(turn_id)
      unless lease.session_id == id, do: fail(:not_found)

      case lease.application_turn["status"] do
        "committed" -> fail(:conflict)
        "accepted" -> lease |> expire!() |> cancel_pending!() |> accepted()
        _ -> accepted(lease)
      end
    end)
  end

  @doc "Archive cancels pending application work atomically; restore never revives it."
  def archive(id, at, scope) do
    transaction(fn ->
      session = session!(id)
      unless StudioChat.get_session(id, scope), do: fail(:not_found)

      unless is_nil(at) do
        Repo.all(
          from l in ExecutionLease,
            where:
              l.session_id == ^id and l.provider == "application" and
                l.status in ["leased", "running", "disconnected"],
            lock: "FOR UPDATE"
        )
        |> Enum.each(&cancel_lease!(&1, "archived"))
      end

      session |> Ecto.Changeset.change(archived_at: at) |> Repo.update!()
    end)
  end

  defp personal!({:personal, ws, user}, login, id) do
    session = session!(id)

    unless session.owner_workspace_id == ws and session.owner_user_id == user,
      do: fail(:not_found)

    actor!(ws, user, login)
    session
  end

  defp personal!(_, _, _), do: fail(:forbidden)

  defp session!(id) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: fail(:not_found)
    Repo.one(from s in Session, where: s.id == ^id, lock: "FOR UPDATE") || fail(:not_found)
  end

  defp lease!(id) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: fail(:not_found)

    Repo.one(
      from l in ExecutionLease,
        where: l.id == ^id and l.provider == "application",
        lock: "FOR UPDATE"
    ) || fail(:not_found)
  end

  defp state!(session) do
    state = session.application_state
    unless is_map(state) and is_nil(session.archived_at), do: fail(:application_unavailable)
    binding = binding!(state["binding"]["id"], session.owner_workspace_id)
    unless binding == state["binding"], do: fail(:application_unavailable)
    state
  end

  defp machine!(host, id) do
    # Read only the parent id first, then lock session before lease consistently.
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: fail(:not_found)

    sid =
      Repo.one(
        from l in ExecutionLease,
          where: l.id == ^id and l.provider == "application" and l.host_id == ^host.id,
          select: l.session_id
      ) || fail(:not_found)

    session = session!(sid)
    lease = lease!(id)
    state = state!(session)
    current = host!(host.id, session.owner_workspace_id)

    unless current.credential_version == host.credential_version and
             current.credential_hash == host.credential_hash and
             state["binding"]["host_id"] == host.id and lease.workspace_id == current.workspace_id and
             lease.application_turn["binding"] == state["binding"],
           do: fail(:forbidden)

    actor!(
      session.owner_workspace_id,
      session.owner_user_id,
      lease.application_turn["actor_session_id"]
    )

    {session, lease, state}
  end

  defp actor!(ws, user_id, login_id) do
    unless match?({:ok, _}, Ecto.UUID.cast(login_id)), do: fail(:session_lost)
    now = DateTime.utc_now()

    login =
      Repo.one(
        from s in UserSession,
          where: s.id == ^login_id and s.user_id == ^user_id and is_nil(s.revoked_at),
          where: is_nil(s.expires_at) or s.expires_at > ^now,
          lock: "FOR SHARE"
      ) || fail(:session_lost)

    user = Repo.get(User, user_id) || fail(:session_lost)

    unless UserSession.within_org_policy?(
             login,
             Tenancy.org_session_policy_for_user(user_id),
             now
           ),
           do: fail(:session_lost)

    unless Accounts.mfa_enrolled?(user) or not Tenancy.org_requires_mfa_for_user?(user_id),
      do: fail(:forbidden)

    seat =
      Repo.one(
        from m in Membership,
          where:
            m.workspace_id == ^ws and m.principal_id == ^user_id and m.principal_type == "user",
          lock: "FOR SHARE"
      ) || fail(:forbidden)

    unless Barkpark.Tenancy.Auth.seat_capabilities(user, seat, ws).read, do: fail(:forbidden)
    :ok
  end

  defp host!(id, ws) do
    now = DateTime.utc_now()

    Repo.one(
      from h in RegisteredHost,
        where:
          h.id == ^id and h.workspace_id == ^ws and is_nil(h.revoked_at) and
            not is_nil(h.enrolled_at) and h.credential_expires_at > ^now,
        lock: "FOR SHARE"
    ) || fail(:forbidden)
  end

  defp binding!(app, ws) do
    case ApplicationBinding.resolve(app, ws) do
      {:ok, binding} -> binding
      {:error, reason} -> fail(reason)
    end
  end

  defp live!(lease) do
    unless lease.status in ["leased", "running"] and
             lease.application_turn["status"] == "accepted" and is_nil(lease.revoked_at) and
             not expired?(lease, DateTime.utc_now()),
           do: fail(:turn_unavailable)
  end

  defp expired?(lease, now),
    do:
      DateTime.compare(deadline!(lease), now) != :gt or
        DateTime.compare(lease.expires_at, now) != :gt

  defp expire!(lease) do
    cond do
      lease.application_turn["status"] != "accepted" ->
        lease

      not is_nil(lease.revoked_at) or lease.status == "cancelled" ->
        cancel_lease!(lease, "revoked")

      expired?(lease, DateTime.utc_now()) ->
        cancel_lease!(lease, "expired")

      true ->
        lease
    end
  end

  defp cancel_pending!(%ExecutionLease{application_turn: %{"status" => "accepted"}} = lease),
    do: cancel_lease!(lease, "cancelled")

  defp cancel_pending!(lease), do: lease

  defp last_answer(_id, %{"last_turn_id" => nil}), do: nil

  defp last_answer(id, state) do
    lease = Repo.get!(ExecutionLease, state["last_turn_id"])
    message = Repo.get_by!(Message, id: lease.application_turn["message_id"], session_id: id)

    %{
      message_id: message.id,
      turn_id: lease.id,
      revision: state["revision"],
      answer: message.metadata["application"]["answer"]
    }
  end

  defp deadline!(lease) do
    {:ok, deadline, _} = DateTime.from_iso8601(lease.application_turn["deadline"])
    deadline
  end

  defp cancel_lease!(lease, reason) do
    lease
    |> Ecto.Changeset.change(
      status: "cancelled",
      revoked_at: DateTime.utc_now(),
      epoch: lease.epoch + 1,
      application_turn: Map.put(lease.application_turn, "status", reason)
    )
    |> Repo.update!()
  end

  defp validate_request!(attrs) do
    unless Enum.sort(Map.keys(attrs)) == ~w(expected_revision query request_id) and
             text?(attrs["query"], 6400) and text?(attrs["request_id"], 100) and
             revision?(attrs["expected_revision"]),
           do: fail(:invalid_request)
  end

  defp validate_commit!(attrs, state) do
    result = attrs["result"]

    unless Enum.sort(Map.keys(attrs)) == ~w(epoch expected_revision request_digest result) and
             is_integer(attrs["epoch"]) and attrs["epoch"] > 0 and
             revision?(attrs["expected_revision"]) and is_map(result), do: fail(:invalid_request)

    unless Enum.sort(Map.keys(result)) ==
             ~w(answer context contract_version selection source_identities) and
             result["contract_version"] == state["binding"]["contract_version"] and
             is_map(result["context"]) and is_list(result["selection"]) and
             length(result["selection"]) <= 3 and is_list(result["source_identities"]) and
             length(result["source_identities"]) <= 100 and is_map(result["answer"]) and
             Enum.sort(Map.keys(result["answer"])) == ~w(id presentation text) and
             is_map(result["answer"]["presentation"]) and
             text?(result["answer"]["id"], 200) and text?(result["answer"]["text"], 64_000),
           do: fail(:invalid_request)

    case Jason.encode(result) do
      {:ok, json} when byte_size(json) <= 128_000 -> :ok
      _ -> fail(:invalid_request)
    end
  end

  defp revision?(n), do: is_integer(n) and n >= 0 and n <= @max_revision

  defp text?(s, max),
    do: is_binary(s) and byte_size(s) > 0 and byte_size(s) <= max and String.trim(s) != ""

  defp accepted(lease),
    do: %{
      id: lease.id,
      epoch: lease.epoch,
      base_revision: lease.application_turn["base_revision"],
      request_digest: lease.application_turn["request_digest"],
      status: lease.application_turn["status"]
    }

  defp commit_receipt(lease),
    do: %{
      turn_id: lease.id,
      revision: lease.application_turn["committed_revision"],
      message_id: lease.application_turn["message_id"],
      status: "committed"
    }

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp transaction(fun), do: Repo.transaction(fun)
  defp fail(reason), do: Repo.rollback(reason)
end
