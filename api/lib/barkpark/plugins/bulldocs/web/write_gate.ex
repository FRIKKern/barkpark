defmodule Barkpark.Plugins.Bulldocs.Web.WriteGate do
  @moduledoc """
  The parts of the Paper ingest write gate that need no controller state:
  where a token with no home workspace writes when the request names nothing
  (`seat/2`), the typed refusal a write the gate does not approve gets
  (`refuse/2`), and the judgment of the approved workspace itself (`admit/2`:
  refused when archived, then quota and suspension, judged once).
  `BulldocsIngestController` resolves the scope and calls these.

  The seat rule: a token writes in its one seat. For the actions in
  `seat_default_actions/0`, a seat in the default workspace wins among several,
  so a token seated there writes there. Any other number of seats is
  refused with the workspaces the token may name and the command that pins a
  token to one of them, since `bp paper push` and `pull` send no workspace.

  The write rule (`may_write?/2`) is the one answer to "may this caller write
  in workspace X", asked by the controller's door about a workspace the
  request names and, through `write_check/1`, inside a Paper write's
  transaction about the saved row's workspace. It judges only the request's
  `Barkpark.Tenancy.WriteCaller` (the `:ingest` pipeline's `:write_caller`).
  """

  alias Barkpark.Content.{CallerContext, WriteScope}
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Workspace, WriteCaller}
  alias BarkparkWeb.ErrorResponse
  alias BarkparkWeb.Plugs.RequireWithinQuota

  @seat_default_actions [
    :sync,
    :apply_op,
    :propose,
    :apply_session_op,
    :append_session_event,
    :touch_session_conversation
  ]

  @seat_hint "pin a token to one of details.workspaces with bp -s <server> -w <workspace> " <>
               "-p <project> token create <label> --permissions read,write (bp paper push " <>
               "sends no workspace), or name the workspace in a \"workspace\" body field or " <>
               "the x-barkpark-workspace header"

  @doc "The actions where a seat in the default workspace wins among several."
  def seat_default_actions, do: @seat_default_actions

  @doc "The hint on the `workspace_scope_required` refusal."
  def seat_hint, do: @seat_hint

  @doc """
  The workspace a token with no home writes in for `action` when the request
  names none: `{:ok, {workspace_id, nil}}`, or the typed refusal with the slugs
  of every workspace it is seated in.
  """
  def seat(token, action) do
    seats = Tenancy.list_workspaces_for(token.id)
    default = action in @seat_default_actions && Enum.find(seats, & &1.is_default)

    case default do
      %{id: id} ->
        {:ok, {id, nil}}

      _one_seat_or_refused ->
        case WriteScope.infer_write_workspace(CallerContext.from_token(token)) do
          {:ok, ws} ->
            {:ok, {ws.id, nil}}

          {:error, :workspace_scope_required} ->
            {:error, {:workspace_scope_required, slugs(seats)}}
        end
    end
  end

  defp slugs(seats), do: Enum.map(seats, & &1.slug)

  @doc """
  May `caller` write in workspace `ws_id`. Its own permission must include
  writing, and then: `ws_id` is its home, the seat rule lets it write there
  (`may_write_in`), or it is an operator on an ARMED allowlist. False for
  anything but a `WriteCaller` and a workspace id.
  """
  @spec may_write?(WriteCaller.t() | term(), term()) :: boolean()
  def may_write?(%WriteCaller{may_write?: true, may_write_in: seat?} = caller, ws_id)
      when is_binary(ws_id) and is_function(seat?, 1) do
    ws_id == caller.home or caller.operator? == true or seat?.(ws_id) == true
  end

  def may_write?(_caller, _ws_id), do: false

  @doc """
  The `may_write:` predicate a Paper write runs inside its transaction on the
  saved row's workspace (`Content.Papers.SavedCheck`), from the request's
  assigns: `may_write?/2` for its `:write_caller`; a predicate refusing every
  workspace for anything else assigned there, or for a token with no
  `:write_caller`; nil with neither (the shared-secret producer).
  """
  @spec write_check(map()) :: (term() -> boolean()) | nil
  def write_check(%{write_caller: %WriteCaller{} = caller}), do: &may_write?(caller, &1)
  def write_check(%{write_caller: caller}) when not is_nil(caller), do: &refuse_all/1
  def write_check(%{api_token: token}) when not is_nil(token), do: &refuse_all/1
  def write_check(_assigns), do: nil

  defp refuse_all(_ws_id), do: false

  @doc """
  Judge the workspace the gate approved: 409 `workspace_archived` when it is
  archived, else `RequireWithinQuota.judge/3` (suspended, over quota, batch
  caps). The shared secret's `{nil, nil}` is judged on the pipeline's workspace.
  """
  def admit(conn, {ws_id, _project_id}) do
    case approved_workspace(conn, ws_id) do
      nil ->
        conn

      %Workspace{} = ws ->
        if Workspace.archived?(ws) do
          conn
          |> ErrorResponse.emit({:error, {:workspace_archived, ws.slug}})
          |> Plug.Conn.halt()
        else
          RequireWithinQuota.judge(conn, ws, creates: RequireWithinQuota.ingest_creates())
        end
    end
  end

  defp approved_workspace(conn, nil), do: conn.assigns[:current_workspace]

  defp approved_workspace(conn, ws_id) do
    case conn.assigns[:current_workspace] do
      %Workspace{id: ^ws_id} = ws -> ws
      _other -> Tenancy.get_workspace_by_id(ws_id)
    end
  end

  @doc "Render the gate's typed refusal for `reason` and halt."
  def refuse(conn, {:workspace_scope_required, slugs}) do
    conn
    |> ErrorResponse.emit({:error, {:workspace_scope_required, slugs}}, nil, @seat_hint)
    |> Plug.Conn.halt()
  end

  def refuse(conn, {:project_scope_conflict, sent, workspace_id}) do
    conn
    |> ErrorResponse.emit_custom(
      :unprocessable_entity,
      "project_scope_conflict",
      "project #{sent} is not a project of workspace #{workspace_id} — the write " <>
        "was refused rather than stamped with a workspace/project pair no tenant owns",
      %{sent: sent, workspace_id: workspace_id}
    )
    |> Plug.Conn.halt()
  end

  def refuse(conn, {:workspace_scope_conflict, sent, resolved}) do
    conn
    |> ErrorResponse.emit_custom(
      :unprocessable_entity,
      "workspace_scope_conflict",
      "this credential resolves to workspace #{resolved}, but the request addressed " <>
        "#{sent || "another workspace"} — a body field or header is not a credential, so " <>
        "the write was refused rather than retargeted",
      %{sent: sent, resolved: resolved}
    )
    |> Plug.Conn.halt()
  end
end
