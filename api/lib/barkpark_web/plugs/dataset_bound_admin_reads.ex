defmodule BarkparkWeb.Plugs.DatasetBoundAdminReads do
  @moduledoc """
  What a dataset-bound admin token gets on the workspace-level admin reads: the
  audit log, the member roster and its invitations, the token inventories
  (workspace tokens, app tokens, share-edit tokens), run secrets (list, reveal
  and a secret's audit trail, flat and scoped) and the workspace export, which
  carries all of those.

  A token minted with an explicit `dataset` (`ApiToken.dataset_bound?/1`) is
  meant to be held to that dataset (docs/auth.md). These reads name no dataset:
  they answer for a whole workspace, or the instance. One setting decides what
  happens, read at request time:

      config :barkpark, :dataset_bound_admin_reads, :observe   # default
      config :barkpark, :dataset_bound_admin_reads, :enforce

  `BARKPARK_DATASET_BOUND_ADMIN_READS=enforce|observe` in the environment wins
  over the config value; it is read here, not in runtime.exs, which may not
  grow (scripts/file-size-ratchet.py).

    * `:observe` lets the request through unchanged: same status, body and
      headers. After a successful read it writes one log line and one audit
      row (category `access`, action `bound_token.admin_read`): the token id,
      the surface, the route and the workspace id. Never the token, its hash or
      its label, which can hold an email. The row is written after the response
      body is built, on a supervised task where audit dispatch is async (as in
      production), so it is never part of the answer it records.
    * `:enforce` refuses with 403 `forbidden`, reason `dataset_not_bound`,
      with a hint that names the fix.

  Controllers plug it per read action, with `surface:`. It runs after the
  router's own gates, and only for a token that holds the `admin` permission,
  so a caller the route already refuses gets the answer it got before.
  Unbound tokens, user sessions and anonymous callers pass untouched.

  The Studio Activity page asks `refused?/1` and `observe/4` itself.
  """

  @behaviour Plug

  require Logger

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias BarkparkWeb.ErrorResponse

  @action "bound_token.admin_read"
  @message "this token is bound to one dataset and cannot read workspace admin lists"
  @hint "Audit, members, tokens, secrets and the workspace export answer for the whole workspace. Use a token minted without `dataset` (`bp token create --permissions admin` with no -d), or your account. `GET /v1/auth/token` shows the binding. Write and admin tokens minted by bp before 2026-11-13 are bound to production: mint a new one."

  @doc """
  `:observe` (the default) or `:enforce`. `BARKPARK_DATASET_BOUND_ADMIN_READS`
  (`enforce` or `observe`) wins; otherwise the config value, where anything
  but `:enforce` reads as `:observe`.
  """
  @spec mode() :: :observe | :enforce
  def mode do
    case System.get_env("BARKPARK_DATASET_BOUND_ADMIN_READS") do
      "enforce" -> :enforce
      "observe" -> :observe
      _ -> if config_mode() == :enforce, do: :enforce, else: :observe
    end
  end

  defp config_mode, do: Application.get_env(:barkpark, :dataset_bound_admin_reads, :observe)

  @doc "True for a dataset-bound token that holds the `admin` permission."
  @spec bound_admin?(term()) :: boolean()
  def bound_admin?(principal),
    do: ApiToken.dataset_bound?(principal) and Auth.has_permission?(principal, "admin")

  @doc "True when this principal is refused these reads: a bound admin token, in `:enforce`."
  @spec refused?(term()) :: boolean()
  def refused?(principal), do: bound_admin?(principal) and mode() == :enforce

  @doc """
  Record one read of `surface` by a bound admin token: a log line and an audit
  row. A no-op for any other principal. Never raises.
  """
  @spec observe(term(), String.t(), String.t(), binary() | nil) :: :ok
  def observe(principal, surface, route, workspace_id) do
    if bound_admin?(principal), do: record(principal.id, surface, route, workspace_id)
    :ok
  end

  @impl Plug
  def init(opts), do: Keyword.fetch!(opts, :surface)

  @impl Plug
  def call(conn, surface) do
    token = conn.assigns[:api_token]

    cond do
      not bound_admin?(token) ->
        conn

      mode() == :enforce ->
        ErrorResponse.emit(conn, {:error, :forbidden_dataset}, @message, @hint)

      true ->
        Plug.Conn.register_before_send(conn, &after_read(&1, token, surface))
    end
  end

  # Only a read that answered: a refusal or a bad filter read nothing.
  defp after_read(%Plug.Conn{status: status} = conn, token, surface)
       when status in 200..299 do
    observe(token, surface, route(conn), workspace_id(conn, token))
    conn
  end

  defp after_read(conn, _token, _surface), do: conn

  defp route(conn) do
    controller = conn.private |> Map.get(:phoenix_controller) |> inspect()
    "#{conn.method} #{controller}.#{Map.get(conn.private, :phoenix_action)}"
  end

  # A `/w/:ws/p/:proj` route resolved its workspace; a flat route that names a
  # workspace slug (the export) did not, and its `current_workspace` is the
  # stamped Default, so the slug is looked up. Otherwise: the token's own.
  defp workspace_id(%Plug.Conn{path_params: %{"project_slug" => _}} = conn, _token),
    do: id_of(conn.assigns[:current_workspace])

  defp workspace_id(%Plug.Conn{path_params: %{"workspace_slug" => slug}}, _token)
       when is_binary(slug),
       do: id_of(Barkpark.Tenancy.get_workspace_by_slug(slug))

  defp workspace_id(_conn, token), do: token.workspace_id

  defp id_of(%{id: id}), do: id
  defp id_of(_), do: nil

  defp record(token_id, surface, route, workspace_id) do
    Logger.warning(
      "dataset_bound_admin_read token_id=#{token_id} surface=#{surface} " <>
        "route=#{inspect(route)} workspace_id=#{workspace_id || "none"}"
    )

    emit = fn -> emit(token_id, surface, route, workspace_id) end

    # The same switch the audit webhook bridge uses: async in production,
    # inline in tests (config/test.exs), so a test can count the row.
    if Application.get_env(:barkpark, :audit_dispatch_async, true),
      do: Task.Supervisor.start_child(Barkpark.TaskSupervisor, emit),
      else: emit.()
  rescue
    error -> Logger.error("dataset_bound_admin_read record failed: #{Exception.message(error)}")
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
    error -> Logger.error("dataset_bound_admin_read audit failed: #{Exception.message(error)}")
  end
end
