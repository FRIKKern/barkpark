defmodule BarkparkWeb.Studio.SharedPublishAdvisoryTest do
  @moduledoc """
  Studio surfacing of the publish wall's ADVISORY channel
  (authoring-excellence D5/D24): the non-blocking `warnings` the wall queues
  (the 2–4 tag-count norm, the dedup advise band) ride the mutate success
  envelope — but a Studio publish is an agent-facing surface too. `do_action`
  and `bulk_action` now `Warnings.reset()` before the write and drain the
  advisories into the success flash (mirroring `MutateController`), so a
  publish that is LEGAL-but-noisy tells the author why.

  Proven end-to-end through a real Studio mount: a walled `task` carrying ONE
  weighted tag (legal count, outside the 2–4 norm) is bulk-published; the flash
  carries the `label_norm` advisory text.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, LabelFixtures, Tasks}

  @dataset "production"
  @admin_token "publish-advisory-admin"

  setup do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    # Register exactly the fixture tag the 1-tag label set uses.
    LabelFixtures.register_tags!(@dataset, ["fixture-tag-1"])

    # A walled task draft with ONE weighted tag: a LEGAL count (1..12) that is
    # OUTSIDE the 2–4 norm, so publishing it queues the label_norm advisory.
    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "adv-task",
          "title" => "Advisory task",
          "content" =>
            LabelFixtures.with_labels(%{"kind" => "task", "lifecycle_status" => "open"}, 1)
        },
        @dataset,
        scope
      )

    :ok
  end

  # `bulk-publish` is an ADMIN-tier Caps event
  # (arpss-schema-action-write-tier-ruling) and the :admin tier is enforced on
  # EVERY Studio socket, including the anonymous public-demo one. This suite is
  # about the publish advisory, not the gate, so it mounts an admin principal.
  defp admin_conn(conn) do
    {:ok, _} =
      Barkpark.Auth.create_token(@admin_token, "publish advisory admin", @dataset, [
        "read",
        "write",
        "admin"
      ])

    Plug.Test.init_test_session(conn, %{"api_token" => @admin_token})
  end

  test "a 1-tag bulk publish surfaces the label_norm advisory in the success flash", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), scoped_studio("/d/#{@dataset}/studio/task"))

    _ = render_click(view, "toggle-doc-checkbox", %{"id" => "adv-task"})
    html = render_click(view, "bulk-publish", %{})

    # The doc published (legal count — the norm is advisory, never blocking).
    assert {:ok, %{status: "published"}} = Content.get_document("adv-task", "task", @dataset)

    # …and the advisory rode the success flash instead of being dropped.
    assert html =~ "Published 1 of 1"
    assert html =~ "the norm is 2"
  end
end
