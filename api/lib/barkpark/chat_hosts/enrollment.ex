defmodule Barkpark.ChatHosts.Enrollment do
  @moduledoc """
  The answers a person needs when a one-time chat host code does not work
  (/papers/chat-host-enrollment-overhaul, T1).

  `refusal/1` says why `Barkpark.ChatHosts.enroll/2` refused a code. It is read
  only after that refusal, and it looks the code up by its sha256, the same
  unique column enrol uses. A caller who never held a real code (32 random
  bytes) matches no row and gets `:unknown`, the answer every refusal used to
  get, so a guesser learns nothing new. Only the holder of a code that once
  worked learns whether it expired, was replaced, was revoked or was used.

  `name_conflict/2` names the host that already holds a name, so the owner is
  told to make a new code for a waiting host instead of seeing "Could not
  create enrollment".
  """

  import Ecto.Query

  alias Barkpark.ChatHosts.{RegisteredHost, Security}
  alias Barkpark.Repo

  @type refusal :: :expired | :replaced | :revoked | :used | :unknown

  @doc """
  Why the code was refused:

    * `:used` - a machine enrolled with it and is still registered;
    * `:expired` - never used, not revoked, past its 10 minutes;
    * `:replaced` - revoked, and a newer host row took its name (the owner
      made a new code, or registered the machine again);
    * `:revoked` - revoked, with no newer row for its name, whether or not a
      machine had enrolled with it first;
    * `:unknown` - no host row holds this code.
  """
  @spec refusal(String.t()) :: refusal()
  def refusal(code) when is_binary(code) do
    hash = Security.hash_secret(code)

    case Repo.one(from(h in RegisteredHost, where: h.enrollment_hash == ^hash)) do
      nil -> :unknown
      %RegisteredHost{revoked_at: nil, enrolled_at: %DateTime{}} -> :used
      %RegisteredHost{revoked_at: nil} -> :expired
      host -> if replaced?(host), do: :replaced, else: :revoked
    end
  end

  def refusal(_code), do: :unknown

  defp replaced?(%RegisteredHost{} = host) do
    RegisteredHost
    |> where([h], h.workspace_id == ^host.workspace_id and h.name == ^host.name)
    |> where([h], h.id != ^host.id and h.inserted_at > ^host.inserted_at)
    |> Repo.exists?()
  end

  @doc "What the machine is told, with the next step, for each refusal."
  @spec refusal_message(refusal()) :: String.t()
  def refusal_message(:expired),
    do:
      "This one-time code has expired; codes work for 10 minutes. " <>
        "Ask the workspace owner for a new one " <>
        "(bp chat-host new-code <name>, or Make a new code in Studio > Chat hosts)."

  def refusal_message(:replaced),
    do: "A newer code replaced this one. Run enroll again with the newest code for this machine."

  def refusal_message(:revoked),
    do:
      "The workspace owner revoked this machine, so its code no longer works. " <>
        "Ask the owner to register it again (Studio > Chat hosts, or bp chat-host enroll), " <>
        "then run enroll with the new code."

  def refusal_message(:used),
    do:
      "This code was already used to enroll a machine, and each code works once. " <>
        "If this machine is that host, run barkpark-chat-host run. " <>
        "To enroll another machine, ask the workspace owner for a new code."

  def refusal_message(:unknown),
    do:
      "This code is not valid. Check that you copied all of it, " <>
        "or ask the workspace owner for a new one."

  @doc """
  A new one-time code for a host in `workspace_id` that is still waiting to
  enroll. In one transaction the waiting row is revoked and a new row takes
  its name, folders and capabilities with a fresh code, so the old code is
  refused from the moment the new one exists (`refusal/1` then answers
  `:replaced`). The server keeps only the new code's hash, as for any code.

  The waiting row is locked first, so two presses at once make one new code;
  the second finds the row revoked and gets `:not_found`. Answers
  `{:ok, %{host, enrollment_token}}` like `ChatHosts.issue_enrollment/2`, or
  `{:error, :not_found}` (no such host here, or revoked) or
  `{:error, :already_enrolled}`. Who may call it is the caller's check: the
  workspace owner, as for a new host.
  """
  @spec replace_code(String.t(), term()) ::
          {:ok, map()} | {:error, :not_found | :already_enrolled | term()}
  def replace_code(workspace_id, host_id) when is_binary(workspace_id) do
    with {:ok, workspace_id} <- Ecto.UUID.cast(workspace_id),
         {:ok, host_id} <- cast_id(host_id) do
      Repo.transaction(fn ->
        RegisteredHost
        |> where([h], h.workspace_id == ^workspace_id and h.id == ^host_id)
        |> lock("FOR UPDATE")
        |> Repo.one()
        |> replace_locked(workspace_id)
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  def replace_code(_workspace_id, _host_id), do: {:error, :not_found}

  defp cast_id(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast_id(_id), do: :error

  defp replace_locked(nil, _workspace_id), do: Repo.rollback(:not_found)

  defp replace_locked(%RegisteredHost{revoked_at: %DateTime{}}, _workspace_id),
    do: Repo.rollback(:not_found)

  defp replace_locked(%RegisteredHost{enrolled_at: %DateTime{}}, _workspace_id),
    do: Repo.rollback(:already_enrolled)

  defp replace_locked(%RegisteredHost{} = host, workspace_id) do
    with {:ok, _revoked} <-
           host |> RegisteredHost.revoke_changeset(DateTime.utc_now()) |> Repo.update(),
         {:ok, issued} <-
           Barkpark.ChatHosts.issue_enrollment(workspace_id, %{
             name: host.name,
             approved_roots: host.approved_roots,
             protocol_version: host.protocol_version,
             capabilities: host.capabilities
           }) do
      issued
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  The host in `workspace_id` that holds `name` (not revoked), as
  `{:pending, host_id}` for one still waiting to enroll or `{:enrolled, host_id}`,
  or nil.
  """
  @spec name_conflict(String.t(), term()) :: {:pending | :enrolled, String.t()} | nil
  def name_conflict(workspace_id, name) when is_binary(workspace_id) and is_binary(name) do
    RegisteredHost
    |> where([h], h.workspace_id == ^workspace_id and h.name == ^name and is_nil(h.revoked_at))
    |> select([h], {h.id, h.enrolled_at})
    |> Repo.one()
    |> case do
      nil -> nil
      {id, nil} -> {:pending, id}
      {id, _enrolled_at} -> {:enrolled, id}
    end
  end

  def name_conflict(_workspace_id, _name), do: nil

  @doc "True when the changeset was refused only because the name is taken."
  @spec name_taken?(term()) :: boolean()
  def name_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:workspace_id, {_message, opts}} -> opts[:constraint] == :unique
      {:name, {_message, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  def name_taken?(_), do: false

  @doc "What the owner is told when the name is taken."
  @spec name_taken_message(String.t(), :pending | :enrolled) :: String.t()
  def name_taken_message(name, :pending),
    do:
      "A machine named #{name} is already waiting to enroll. " <>
        "Make a new code for it instead; the old code then stops working."

  def name_taken_message(name, :enrolled),
    do:
      "A machine named #{name} is already enrolled. " <>
        "Pick another name, or revoke that machine first."

  @doc """
  The machines this workspace revoked after they had enrolled, newest first,
  for the Chat hosts page's "Recently revoked" line. A waiting row that was
  replaced or removed is left out: it never ran anything. One row per name,
  the newest revocation.
  """
  @spec recently_revoked(String.t(), pos_integer()) :: [map()]
  def recently_revoked(workspace_id, limit \\ 5) when is_binary(workspace_id) do
    newest_per_name =
      RegisteredHost
      |> where([h], h.workspace_id == ^workspace_id)
      |> where([h], not is_nil(h.revoked_at) and not is_nil(h.enrolled_at))
      |> distinct([h], h.name)
      |> order_by([h], asc: h.name, desc: h.revoked_at)
      |> select([h], %{id: h.id, name: h.name, revoked_at: h.revoked_at})

    from(r in subquery(newest_per_name), order_by: [desc: r.revoked_at], limit: ^limit)
    |> Repo.all()
  end
end
