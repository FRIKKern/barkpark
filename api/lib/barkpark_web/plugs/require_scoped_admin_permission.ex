defmodule BarkparkWeb.Plugs.RequireScopedAdminPermission do
  @moduledoc """
  On a SCOPED route (`/w/:workspace_slug/...`), require the `admin`
  PERMISSION as well as an admin seat: `TenancyAuth.authorize(token, ws,
  :admin)`, the predicate the scoped workspace audit (`AuditController`)
  uses. Refused with 403 `missing_capability` and the hint that names
  `admin` (`{:forbidden_capability, :admin}`).

  `:scoped_admin` (`RequireWorkspaceRole`) checks the seat ROLE, plus
  `write` on writes. Some admin surfaces need more, because their flat twins
  ride `:flat_admin_api` (RequireAdmin, the `admin` permission) and
  docs/auth.md lists them under `admin`: a token holding `read` or
  `read`+`write`, raised to an admin seat by hand, must not reach them on the
  scoped tier either. Mounted as a controller plug by:

    * `SecretController` (task-23ed7ba485104620): every action reveals or
      sets a secret value.
    * `WebhookController` (task-3e1492d5869d66b0): create and rotate return
      the signing secret, and update can set one.

  A flat route carries no `workspace_slug` and passes through untouched.
  A scoped route whose workspace assign is missing or not a UUID also passes
  through: the controller's own scope resolution fails closed on it (the
  secrets D199 guard answers an opaque 404), and this plug must not turn that
  404 into a 403.
  """

  import Plug.Conn

  alias Barkpark.Content.Errors
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  def init(opts), do: opts

  def call(%Plug.Conn{path_params: %{"workspace_slug" => _}} = conn, _opts) do
    with %{id: id} <- conn.assigns[:current_workspace],
         ws_id when is_binary(ws_id) <- Barkpark.Repo.uuid_or_nil(id) do
      case TenancyAuth.authorize(conn.assigns[:api_token], ws_id, :admin) do
        :ok -> conn
        _ -> refuse(conn)
      end
    else
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp refuse(conn) do
    env = Errors.to_envelope({:error, {:forbidden_capability, :admin}}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
