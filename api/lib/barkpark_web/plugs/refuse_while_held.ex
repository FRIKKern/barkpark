defmodule BarkparkWeb.Plugs.RefuseWhileHeld do
  @moduledoc """
  Managed-mode refusal for the route groups Barkdown does not offer during a
  library switch (Barkdown decision D-managed-writers): tenancy and workspace
  administration, account, SSO, SCIM and access management, operator surfaces
  (secrets, plugin settings, schema CRUD, webhooks, sharing, status incidents)
  and the Studio chat and cycle-fleet APIs.

  Those writers are not doors. Instead every mutating request on their pipelines
  takes a zero-width admission from the instance coordinator; a held instance
  refuses the request with the same 503 `storage_unavailable` /
  `write_admission_<state>` envelope a door renders, before any controller runs.
  Reads pass. A passthrough unless `config :barkpark, :write_admission` is
  enabled, so ordinary servers change nothing.
  """

  import Plug.Conn

  alias Barkpark.ManagedRuntime.WriteAdmission.Door

  @reads ~w(GET HEAD OPTIONS)

  def init(opts), do: opts

  def call(%Plug.Conn{method: method} = conn, _opts) when method in @reads, do: conn

  # The hold endpoint is the one admin write that must answer while held.
  def call(%Plug.Conn{path_info: ["v1", "admin", "write-admission" | _]} = conn, _opts), do: conn

  def call(conn, _opts) do
    if Door.enabled?() do
      case Door.admit(fn -> :ok end) do
        :ok -> conn
        {:error, {:write_admission, _}} = refused -> refuse(conn, refused)
      end
    else
      conn
    end
  end

  defp refuse(conn, refused) do
    env = Barkpark.Content.Errors.to_envelope(refused, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
