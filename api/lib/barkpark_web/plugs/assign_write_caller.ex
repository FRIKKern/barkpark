defmodule BarkparkWeb.Plugs.AssignWriteCaller do
  @moduledoc """
  Turns the `:ingest` pipeline's verified token into a
  `Barkpark.Tenancy.WriteCaller`, assigned as `:write_caller`, so a feature's
  write gate judges what the caller may write without naming an auth module.

  Runs after `RequireIngestToken`. The shared-secret arm carries no
  `:api_token` and gets no `:write_caller`.

    * `home` — the token's `workspace_id`;
    * `may_write?` — `Tenancy.Auth.permits?(token, :write)`;
    * `operator?` — the token is on an ARMED operator allowlist
      (`RequirePlatformOperator`). An unset allowlist admits every admin
      token, so it counts as no operator here;
    * `may_write_in` — `&(Tenancy.Auth.authorize(token, &1, :write) == :ok)`,
      the whole seat rule, asked when the gate judges a workspace.
  """

  @behaviour Plug

  import Plug.Conn

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.WriteCaller
  alias BarkparkWeb.Plugs.RequirePlatformOperator

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{api_token: %ApiToken{} = token}} = conn, _opts),
    do: assign(conn, :write_caller, build(token))

  def call(conn, _opts), do: conn

  @doc "The `WriteCaller` for a verified token."
  @spec build(ApiToken.t()) :: WriteCaller.t()
  def build(%ApiToken{} = token) do
    %WriteCaller{
      home: token.workspace_id,
      may_write?: Tenancy.Auth.permits?(token, :write),
      operator?: armed_operator?(token),
      may_write_in: fn ws_id -> Tenancy.Auth.authorize(token, ws_id, :write) == :ok end
    }
  end

  defp armed_operator?(token) do
    case RequirePlatformOperator.allowlist() do
      %{emails: [], token_ids: []} -> false
      _ -> RequirePlatformOperator.permits?(token)
    end
  end
end
