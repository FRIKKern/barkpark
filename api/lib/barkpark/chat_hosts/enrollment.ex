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

    * `:used` - a machine already enrolled with it (whatever happened since);
    * `:expired` - never used, not revoked, past its 10 minutes;
    * `:replaced` - never used, revoked, and a newer host row took its name
      (the owner made a new code);
    * `:revoked` - never used, revoked, with no newer row for its name;
    * `:unknown` - no host row holds this code.
  """
  @spec refusal(String.t()) :: refusal()
  def refusal(code) when is_binary(code) do
    hash = Security.hash_secret(code)

    case Repo.one(from(h in RegisteredHost, where: h.enrollment_hash == ^hash)) do
      nil -> :unknown
      %RegisteredHost{enrolled_at: %DateTime{}} -> :used
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
        "Ask the workspace owner for a new one (Studio > Chat hosts > Make a new code)."

  def refusal_message(:replaced),
    do: "A newer code replaced this one. Run enroll again with the newest code for this machine."

  def refusal_message(:revoked),
    do:
      "The workspace owner removed this machine before it enrolled. " <>
        "Ask the owner to register it again."

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
end
