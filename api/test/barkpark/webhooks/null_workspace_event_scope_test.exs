defmodule Barkpark.Webhooks.NullWorkspaceEventScopeTest do
  @moduledoc """
  Owner ruling #51, RQ2 (task-6132833921b7dc36): an event that names no
  workspace reaches only shared-layer (NULL-workspace) webhooks.

  `active_webhooks_for/4` with a nil/absent workspace used to apply no tenant
  filter at all, so a workspace-less event fanned out to every workspace's
  webhooks in the dataset.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Webhooks

  @dataset "null-ws-scope"

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)

    {:ok, ws_hook} =
      Webhooks.create_webhook(
        %{
          "name" => "tenant-hook",
          "url" => "http://tenant.test/hook",
          "dataset" => @dataset,
          "secret" => "s"
        },
        workspace_id: ws.id,
        project_id: proj.id
      )

    {:ok, shared_hook} =
      Webhooks.create_webhook(%{
        "name" => "shared-hook",
        "url" => "http://shared.test/hook",
        "dataset" => @dataset,
        "secret" => "s"
      })

    assert is_nil(shared_hook.workspace_id)
    %{ws: ws, ws_hook: ws_hook, shared_hook: shared_hook}
  end

  defp selected(opts),
    do: @dataset |> Webhooks.active_webhooks_for("publish", "post", opts) |> Enum.map(& &1.id)

  test "a workspace-less event selects only the shared-layer webhook", ctx do
    assert selected([]) == [ctx.shared_hook.id]
    assert selected(workspace_id: nil, project_id: nil) == [ctx.shared_hook.id]
  end

  test "a workspace event still selects that workspace's webhook (control)", ctx do
    assert ctx.ws_hook.id in selected(workspace_id: ctx.ws.id)
  end
end
