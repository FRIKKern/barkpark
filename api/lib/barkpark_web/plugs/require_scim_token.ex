defmodule BarkparkWeb.Plugs.RequireScimToken do
  @moduledoc """
  Resolves the `Authorization: Bearer <scim-token>` to its Organization and
  assigns it as `:scim_org`. A missing/revoked/unknown token is a SCIM 401. The
  token is scoped to exactly one org, so every downstream operation is
  org-isolated.
  """
  import Plug.Conn
  alias Barkpark.Scim

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> raw] <- get_req_header(conn, "authorization"),
         %Barkpark.Tenancy.Organization{} = org <- Scim.resolve_org(raw) do
      assign(conn, :scim_org, org)
    else
      _ ->
        conn
        |> put_status(401)
        |> Phoenix.Controller.json(%{
          "schemas" => ["urn:ietf:params:scim:api:messages:2.0:Error"],
          "status" => "401",
          "detail" => "invalid or missing SCIM bearer token"
        })
        |> halt()
    end
  end
end
