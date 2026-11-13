defmodule Barkpark.Plugins.Bulldocs.Web.ScopeText do
  @moduledoc """
  Refuses an ingest request that names its workspace or project in bytes
  that are not text (`Barkpark.Tenancy.SlugText`): the `workspace` / `project`
  body fields and the `x-barkpark-workspace` / `x-barkpark-project` headers.

  The ingest controller reads a slug that resolves to nothing as "no
  workspace named", and for the shared secret that means the Default
  workspace. Such bytes can name no workspace, so the request is refused
  (422 `invalid_text`, as for paper text) and nothing is written or read.
  """

  import Plug.Conn

  alias Barkpark.Tenancy.SlugText

  @fields ~w(workspace project)
  @headers ~w(x-barkpark-workspace x-barkpark-project)

  def init(opts), do: opts

  def call(conn, _opts) do
    named =
      Enum.map(@fields, &conn.params[&1]) ++ Enum.flat_map(@headers, &get_req_header(conn, &1))

    if Enum.all?(named, &(not is_binary(&1) or SlugText.text?(&1))) do
      conn
    else
      conn
      |> BarkparkWeb.ErrorResponse.emit_fields(:unprocessable_entity, %{
        code: "invalid_text",
        message:
          "the workspace and project named must be valid UTF-8 and cannot contain NUL bytes"
      })
      |> halt()
    end
  end
end
