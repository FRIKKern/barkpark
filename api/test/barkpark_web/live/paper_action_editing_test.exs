defmodule BarkparkWeb.PaperActionEditingTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Barkpark.{Auth, Content, Repo}

  @dataset "production"

  setup %{conn: conn} do
    previous = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    raw = "action-writer-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "Action editing", @dataset, ["read", "write"])
    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  for host <- [:public, :studio] do
    test "#{host}: nested grid Action edits, no-ops, replay, and reload are lossless", %{
      conn: conn
    } do
      host = unquote(host)
      {slug, original} = create_action_grid()
      {view, path} = mount_editor(conn, host, slug)

      assert has_element?(view, "#action-form-call-to-action")
      assert has_element?(view, "#action-form-absent-action")
      assert has_element?(view, "#action-form-nil-action")
      assert has_element?(view, "#action-form-unknown-priority")
      assert has_element?(view, "[data-test-id='paper-action-preview']")
      refute has_element?(view, "#action-form-malformed-action")

      assert has_element?(
               view,
               "[data-test-id='paper-action-contextual-editor'] .bp-paper-edit-readonly"
             )

      refute has_element?(view, "[data-paper-container-kind='action']")
      assert stored(slug).content == original

      for {id, params} <- [
            {"absent-action",
             %{"action-label" => "", "action-href" => "", "action-priority" => "secondary"}},
            {"nil-action",
             %{"action-label" => "", "action-href" => "", "action-priority" => "secondary"}},
            {"unknown-priority",
             %{"action-label" => "Quiet", "action-href" => "/quiet", "action-priority" => "quiet"}}
          ] do
        request = Ecto.UUID.generate()

        render_hook(
          view,
          "paper-block-autosave",
          Map.merge(params, %{
            "block_id" => id,
            "if_rev" => socket_of(view).assigns.paper_rev,
            "request_id" => request
          })
        )

        assert_reply(view, %{saved: true, request_id: ^request})
        after_noop = stored(slug).content
        assert after_noop["blocks"] == original["blocks"]
        assert after_noop["rev"] == original["rev"]
      end

      request = Ecto.UUID.generate()
      if_rev = socket_of(view).assigns.paper_rev

      params = %{
        "block_id" => "call-to-action",
        "action-label" => "Read the verified report",
        "action-href" => "/reports/verified",
        "action-priority" => "primary",
        "if_rev" => if_rev,
        "request_id" => request
      }

      render_hook(view, "paper-block-autosave", params)
      assert_reply(view, %{saved: true, replayed: false, request_id: ^request, rev: saved_rev})

      saved = stored(slug).content
      [before_section] = original["blocks"]
      [after_section] = saved["blocks"]
      assert Map.drop(after_section, ["blocks"]) == Map.drop(before_section, ["blocks"])

      assert Enum.map(after_section["blocks"], & &1["id"]) ==
               Enum.map(before_section["blocks"], & &1["id"])

      before_action = Enum.find(before_section["blocks"], &(&1["id"] == "call-to-action"))
      after_action = Enum.find(after_section["blocks"], &(&1["id"] == "call-to-action"))

      assert Map.drop(after_action, ["label", "href", "priority"]) ==
               Map.drop(before_action, ["label", "href", "priority"])

      assert after_action["label"] == "Read the verified report"
      assert after_action["href"] == "/reports/verified"
      assert after_action["priority"] == "primary"

      assert Enum.reject(after_section["blocks"], &(&1["id"] == "call-to-action")) ==
               Enum.reject(before_section["blocks"], &(&1["id"] == "call-to-action"))

      {:ok, replay_view, _} = live(conn, path)
      toggle_public_editor(replay_view, host)
      render_hook(replay_view, "paper-block-autosave", params)

      assert_reply(replay_view, %{
        saved: true,
        replayed: true,
        request_id: ^request,
        rev: ^saved_rev
      })

      assert stored(slug).content == saved

      assert has_element?(
               replay_view,
               "#action-label-call-to-action[value='Read the verified report']"
             )

      assert has_element?(replay_view, "#action-href-call-to-action[value='/reports/verified']")

      assert has_element?(
               replay_view,
               "#action-priority-call-to-action option[value='primary'][selected]"
             )

      forged = Ecto.UUID.generate()

      render_hook(replay_view, "paper-block-autosave", %{
        "block_id" => "malformed-action",
        "action-label" => "Must not write",
        "if_rev" => socket_of(replay_view).assigns.paper_rev,
        "request_id" => forged
      })

      assert_reply(replay_view, %{saved: false, request_id: ^forged})
      assert stored(slug).content == saved
    end
  end

  defp create_action_grid do
    slug = "action-editing-#{System.unique_integer([:positive])}"

    blocks = [
      %{
        "id" => "action-grid",
        "type" => "section",
        "variant" => "wide",
        "layout" => %{"mode" => "grid", "tracks" => 3, "gap" => "sm"},
        "unknown-section" => %{"keep" => true},
        "blocks" => [
          action("call-to-action", %{
            "label" => "Read the report",
            "href" => "/reports/original",
            "priority" => "secondary",
            "span" => 2,
            "order" => 3,
            "unknown" => %{"keep" => [1, 2]}
          }),
          %{"id" => "sibling", "type" => "paragraph", "content" => text("Sibling stays")},
          action("absent-action", %{"span" => 1, "order" => 2}),
          action("nil-action", %{"label" => nil, "href" => nil, "priority" => nil}),
          action("unknown-priority", %{
            "label" => "Quiet",
            "href" => "/quiet",
            "priority" => "quiet"
          }),
          action("malformed-action", %{"label" => %{"opaque" => true}, "unknown" => "keep"})
        ]
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          title: "Action editing",
          blocks: blocks
        })
      )

    original = Map.put(paper.content, "blocks", blocks)
    paper |> Ecto.Changeset.change(content: original) |> Repo.update!()
    {slug, original}
  end

  defp action(id, extra), do: Map.merge(%{"id" => id, "type" => "action"}, extra)
  defp text(value), do: [%{"type" => "text", "value" => value}]

  defp mount_editor(conn, host, slug) do
    path =
      if host == :public,
        do: "/papers/#{slug}",
        else: scoped_studio("/d/#{@dataset}/studio/paper/#{slug}")

    {:ok, view, _} = live(conn, path)
    toggle_public_editor(view, host)
    {view, path}
  end

  defp toggle_public_editor(view, :public), do: render_click(view, "paper-toggle-edit", %{})
  defp toggle_public_editor(_view, :studio), do: :ok
  defp stored(slug), do: Content.get_paper(slug, @dataset)
  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
