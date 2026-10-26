defmodule Barkpark.Accounts.BootstrapOwner do
  @moduledoc """
  Makes the first human on a fresh instance an owner without SQL or a shell
  (task-2f87e451273f55cc). Set `BARKPARK_BOOTSTRAP_OWNER_EMAIL` and boot: when
  the instance has no users yet, this creates a confirmed user with that email
  and seats it as `owner` of the default workspace, and writes a
  `membership` / `bootstrap_owner_created` audit event.

  It runs once per boot and does nothing when the setting is unset or any user
  exists, so a second boot and every existing install are unchanged. The owner
  signs in through SSO (attach the default workspace to the SSO organization)
  or sets a password with the reset link. Two replicas booting at once race on
  the unique email, and the loser's transaction rolls back.
  """
  require Logger

  alias Barkpark.{Accounts, Audit, Repo, Tenancy}
  alias Barkpark.Accounts.User

  @spec run(String.t() | nil) :: {:ok, User.t()} | :skipped | {:error, term()}
  def run(email \\ Application.get_env(:barkpark, :bootstrap_owner_email))

  def run(email) when is_binary(email) and email != "" do
    with false <- Repo.exists?(User),
         %{} = ws <- Tenancy.get_default_workspace() do
      create(String.downcase(String.trim(email)), ws)
    else
      true ->
        :skipped

      nil ->
        Logger.warning("[BootstrapOwner] no default workspace; owner not created")
        :skipped
    end
  end

  def run(_email), do: :skipped

  defp create(email, ws) do
    Repo.transaction(fn ->
      password = Base.encode16(:crypto.strong_rand_bytes(32))

      with {:ok, user} <- Accounts.register_user(%{email: email, password: password}),
           user = Accounts.confirm_provisioned_user(user),
           {:ok, _} <- Tenancy.Auth.create_membership(ws.id, user.id, "owner", "user"),
           {:ok, _} <-
             Audit.emit(%{
               category: "membership",
               action: "bootstrap_owner_created",
               subject: user.id,
               actor_type: "system",
               workspace_id: ws.id,
               metadata: %{"email" => email, "workspace_slug" => ws.slug}
             }) do
        Logger.info("[BootstrapOwner] #{email} is now owner of workspace #{ws.slug}")
        user
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
