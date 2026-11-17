defmodule BarkparkWeb.Plugs.DatasetBoundAdminWrites do
  @moduledoc """
  What a dataset-bound admin token gets on the workspace-level admin WRITES:
  seating, re-roling and removing members, inviting and withdrawing
  invitations, minting, revoking and rotating tokens, setting and deleting run
  secrets (flat and scoped), the email form of a login ticket and the Cloud
  seat repairs (deprovision, seat restore).

  The twin of `BarkparkWeb.Plugs.DatasetBoundAdminReads`, on the same
  predicate (`DatasetBoundAdminReads.bound_admin?/1`: a token minted with an
  explicit `dataset` that holds `admin`) and the same switch
  (`DatasetBoundAdminReads.mode/0`: `BARKPARK_DATASET_BOUND_ADMIN_READS`, else
  `config :barkpark, :dataset_bound_admin_reads`, default `:observe`). One
  switch turns both on.

    * `:observe` lets the write through unchanged. After a write that
      answered 2xx it writes one log line and one audit row (category
      `access`, action `bound_token.admin_write`): the token id, the surface,
      the route and the workspace id. Never the token, its hash or its label.
    * `:enforce` refuses with 403 `forbidden`, reason `dataset_not_bound`,
      before the action runs, so nothing changes.

  Exempt in both modes, and not recorded: a bound token revoking ITSELF
  (`own_token_param:` names the path param that holds the target token id).
  Barkpark Cloud's admin-token rotation revokes the old token with the old
  token; refusing that would leave a box half rotated.

  Controllers plug it per write action, with `surface:`. `only_with_param:`
  limits it to requests whose params carry that key as a non-empty string
  (the email form of `POST /v1/auth/login-tickets`). Unbound tokens, user
  sessions and anonymous callers pass untouched.
  """

  @behaviour Plug

  require Logger

  alias BarkparkWeb.ErrorResponse
  alias BarkparkWeb.Plugs.DatasetBoundAdminReads

  @action "bound_token.admin_write"
  @message "this token is bound to one dataset and cannot change workspace members, tokens or secrets"
  @hint "Members, invitations, tokens and secrets belong to the whole workspace. Use a token minted without `dataset` (`bp token create --permissions admin` with no -d), or your account. `GET /v1/auth/token` shows the binding. Write and admin tokens minted by bp before 2026-11-13 are bound to production: mint a new one."

  @doc "The audit action an observed write is recorded under."
  def action, do: @action

  @impl Plug
  def init(opts) do
    %{
      surface: Keyword.fetch!(opts, :surface),
      own: Keyword.get(opts, :own_token_param),
      only_with: Keyword.get(opts, :only_with_param)
    }
  end

  @impl Plug
  def call(conn, opts) do
    token = conn.assigns[:api_token]

    cond do
      not DatasetBoundAdminReads.bound_admin?(token) -> conn
      not applies?(conn, opts.only_with) -> conn
      own_token?(conn, token, opts.own) -> conn
      DatasetBoundAdminReads.mode() == :enforce -> refuse(conn)
      true -> Plug.Conn.register_before_send(conn, &after_write(&1, token, opts.surface))
    end
  end

  @doc "The 403 a bound admin token gets on these writes in `:enforce`."
  def refuse(conn), do: ErrorResponse.emit(conn, {:error, :forbidden_dataset}, @message, @hint)

  defp applies?(_conn, nil), do: true

  defp applies?(conn, key) do
    case conn.params[key] do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp own_token?(_conn, _token, nil), do: false
  defp own_token?(conn, %{id: id}, param), do: conn.path_params[param] == id

  # Only a write that answered: a refusal changed nothing.
  defp after_write(%Plug.Conn{status: status} = conn, token, surface)
       when status in 200..299 do
    record(token.id, surface, route(conn), workspace_id(conn, token))
    conn
  end

  defp after_write(conn, _token, _surface), do: conn

  defp route(conn) do
    controller = conn.private |> Map.get(:phoenix_controller) |> inspect()
    "#{conn.method} #{controller}.#{Map.get(conn.private, :phoenix_action)}"
  end

  # A `/w/:ws/p/:proj` route resolved its workspace; a flat route records the
  # token's own.
  defp workspace_id(%Plug.Conn{path_params: %{"project_slug" => _}} = conn, _token) do
    case conn.assigns[:current_workspace] do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp workspace_id(_conn, token), do: token.workspace_id

  defp record(token_id, surface, route, workspace_id) do
    Logger.warning(
      "dataset_bound_admin_write token_id=#{token_id} surface=#{surface} " <>
        "route=#{inspect(route)} workspace_id=#{workspace_id || "none"}"
    )

    emit = fn -> emit(token_id, surface, route, workspace_id) end

    # Async in production, inline in tests (config/test.exs), as for the reads.
    if Application.get_env(:barkpark, :audit_dispatch_async, true),
      do: Task.Supervisor.start_child(Barkpark.TaskSupervisor, emit),
      else: emit.()
  rescue
    error -> Logger.error("dataset_bound_admin_write record failed: #{Exception.message(error)}")
  end

  defp emit(token_id, surface, route, workspace_id) do
    Barkpark.Audit.emit(%{
      category: "access",
      action: @action,
      subject: token_id,
      actor_type: "api_token",
      actor_id: token_id,
      workspace_id: workspace_id,
      metadata: %{"surface" => surface, "route" => route}
    })
  rescue
    error -> Logger.error("dataset_bound_admin_write audit failed: #{Exception.message(error)}")
  end
end
