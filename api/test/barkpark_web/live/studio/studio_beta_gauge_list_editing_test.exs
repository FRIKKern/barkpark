defmodule BarkparkWeb.Studio.StudioBetaGaugeListEditingTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}

  @dataset "production"
  @doc_type "beta_gauge_list_editing"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Beta gauge-list editing",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    :ok
  end

  test "share form preserves opaque data, rejects invalid numbers, and accepts a corrected draft",
       %{conn: conn} do
    snapshot = [%{"status" => "done", "opaque" => [1, 2]}]

    block = %{
      "id" => "gauges",
      "type" => "gauge-list",
      "mode" => "share",
      "title" => "Before",
      "max" => 100,
      "rows" => [
        %{
          "label" => "Alpha",
          "value" => 10,
          "note" => "Old note",
          "metadata" => %{"source" => "authored"}
        },
        %{"label" => "Beta", "value" => 20, "note" => "", "unknown" => ["keep"]}
      ],
      "snapshot" => snapshot,
      "groupBy" => "status",
      "unknown" => %{"parent" => true}
    }

    doc = create_document!("share", block)
    {view, _path} = mount_beta(conn, doc.doc_id)

    assert has_element?(view, "#gauge-list-form-gauges")
    assert has_element?(view, "#gauge-list-form-gauges [name='gauge-count'][value='2']")
    refute has_element?(view, "#gauge-list-form-gauges [name='snapshot']")

    request_id = Ecto.UUID.generate()

    params =
      share_params(block, %{
        "title" => "After",
        "max" => "120",
        "gauge-0-label" => "Alpha edited",
        "gauge-0-value" => "15",
        "gauge-0-note" => "New note"
      })
      |> write_meta(view, request_id)

    render_hook(view, "paper-block-autosave", params)

    assert_reply(view, %{
      saved: true,
      replayed: false,
      request_id: ^request_id,
      rev: committed_rev
    })

    saved = stored_block(doc.doc_id)
    assert saved["title"] == "After"
    assert saved["max"] == 120

    assert Enum.at(saved["rows"], 0) == %{
             "label" => "Alpha edited",
             "value" => 15,
             "note" => "New note",
             "metadata" => %{"source" => "authored"}
           }

    assert Enum.at(saved["rows"], 1)["unknown"] == ["keep"]
    assert saved["snapshot"] == snapshot
    assert saved["groupBy"] == "status"
    assert saved["unknown"] == %{"parent" => true}

    invalid_request = Ecto.UUID.generate()

    invalid_params =
      share_params(saved, %{"gauge-1-value" => "not-a-number"})
      |> write_meta(view, invalid_request)

    render_hook(view, "paper-block-autosave", invalid_params)

    assert_reply(view, %{
      saved: false,
      rejected: "validation",
      current_rev: ^committed_rev,
      request_id: ^invalid_request
    })

    assert stored_block(doc.doc_id) == saved

    corrected_request = Ecto.UUID.generate()

    corrected_params =
      share_params(saved, %{"gauge-1-value" => "35"})
      |> write_meta(view, corrected_request)

    render_hook(view, "paper-block-autosave", corrected_params)

    assert_reply(view, %{
      saved: true,
      replayed: false,
      request_id: ^corrected_request
    })

    corrected = stored_block(doc.doc_id)
    assert Enum.at(corrected["rows"], 1)["value"] == 35
    assert corrected["snapshot"] == snapshot
    assert corrected["unknown"] == %{"parent" => true}
  end

  test "share row actions apply once and exact retries do not duplicate or repeat them", %{
    conn: conn
  } do
    block = %{
      "id" => "gauges",
      "type" => "gauge-list",
      "mode" => "share",
      "rows" => [
        %{"label" => "First", "value" => 1, "note" => "", "unknown" => "first"},
        %{"label" => "Second", "value" => 2, "note" => "", "unknown" => "second"}
      ],
      "snapshot" => [%{"opaque" => true}]
    }

    doc = create_document!("actions", block)
    {view, _path} = mount_beta(conn, doc.doc_id)

    add_params =
      share_params(block, %{"gauge-action" => "add"})
      |> write_meta(view, Ecto.UUID.generate())

    after_add = apply_and_replay(view, doc.doc_id, add_params)
    assert Enum.map(after_add["rows"], & &1["label"]) == ["First", "Second", ""]

    up_params =
      share_params(after_add, %{"gauge-action" => "up:2"})
      |> write_meta(view, Ecto.UUID.generate())

    after_up = apply_and_replay(view, doc.doc_id, up_params)
    assert Enum.map(after_up["rows"], & &1["label"]) == ["First", "", "Second"]
    assert Enum.at(after_up["rows"], 2)["unknown"] == "second"

    remove_params =
      share_params(after_up, %{"gauge-action" => "remove:1"})
      |> write_meta(view, Ecto.UUID.generate())

    after_remove = apply_and_replay(view, doc.doc_id, remove_params)
    assert Enum.map(after_remove["rows"], & &1["label"]) == ["First", "Second"]
    assert Enum.map(after_remove["rows"], & &1["unknown"]) == ["first", "second"]
    assert after_remove["snapshot"] == [%{"opaque" => true}]
  end

  test "count grouping and both mode switches preserve snapshot and concealed rows", %{conn: conn} do
    snapshot = [
      %{"status" => "done", "priority" => "high", "opaque" => %{"source" => "runtime"}}
    ]

    rows = [
      %{"label" => "Concealed", "value" => 4, "note" => "Keep", "unknown" => true}
    ]

    block = %{
      "id" => "gauges",
      "type" => "gauge-list",
      "mode" => "count",
      "title" => "Tasks",
      "groupBy" => "status",
      "snapshot" => snapshot,
      "rows" => rows,
      "max" => 10,
      "unknown" => "parent"
    }

    doc = create_document!("count", block)
    {view, _path} = mount_beta(conn, doc.doc_id)

    assert has_element?(view, "#gauge-list-form-gauges [name='groupBy'][value='status']")
    refute has_element?(view, "#gauge-list-form-gauges [name='snapshot']")
    refute has_element?(view, "#gauge-list-form-gauges [name='gauge-count']")

    grouped_request = Ecto.UUID.generate()

    render_hook(
      view,
      "paper-block-autosave",
      write_meta(
        %{
          "block_id" => "gauges",
          "title" => "Work",
          "mode" => "count",
          "groupBy" => "priority"
        },
        view,
        grouped_request
      )
    )

    assert_reply(view, %{saved: true, replayed: false, request_id: ^grouped_request})
    grouped = stored_block(doc.doc_id)
    assert grouped["title"] == "Work"
    assert grouped["groupBy"] == "priority"
    assert grouped["snapshot"] == snapshot
    assert grouped["rows"] == rows

    to_share_request = Ecto.UUID.generate()

    render_hook(
      view,
      "paper-block-autosave",
      write_meta(
        %{
          "block_id" => "gauges",
          "title" => "Work",
          "mode" => "share",
          "groupBy" => "priority"
        },
        view,
        to_share_request
      )
    )

    assert_reply(view, %{saved: true, replayed: false, request_id: ^to_share_request})
    shared = stored_block(doc.doc_id)
    assert shared["mode"] == "share"
    assert shared["groupBy"] == "priority"
    assert shared["snapshot"] == snapshot
    assert shared["rows"] == rows
    assert has_element?(view, "#gauge-list-form-gauges [name='gauge-count'][value='1']")

    to_count_request = Ecto.UUID.generate()

    render_hook(
      view,
      "paper-block-autosave",
      shared
      |> share_params(%{"mode" => "count"})
      |> write_meta(view, to_count_request)
    )

    assert_reply(view, %{saved: true, replayed: false, request_id: ^to_count_request})
    counted = stored_block(doc.doc_id)
    assert counted["mode"] == "count"
    assert counted["groupBy"] == "priority"
    assert counted["snapshot"] == snapshot
    assert counted["rows"] == rows
    assert counted["unknown"] == "parent"
    assert has_element?(view, "#gauge-list-form-gauges [name='groupBy'][value='priority']")
    refute has_element?(view, "#gauge-list-form-gauges [name='gauge-count']")
  end

  defp apply_and_replay(view, doc_id, params) do
    request_id = params["request_id"]
    render_hook(view, "paper-edit-block", params)

    assert_reply(view, %{
      saved: true,
      replayed: false,
      request_id: ^request_id,
      rev: committed_rev
    })

    after_write = stored_block(doc_id)
    render_hook(view, "paper-edit-block", params)

    assert_reply(view, %{
      saved: true,
      replayed: true,
      request_id: ^request_id,
      rev: ^committed_rev
    })

    assert stored_block(doc_id) == after_write
    after_write
  end

  defp share_params(block, overrides) do
    rows = block["rows"]

    row_params =
      rows
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {row, index}, params ->
        Map.merge(params, %{
          "gauge-#{index}-label" => to_string(row["label"] || ""),
          "gauge-#{index}-value" => to_string(row["value"] || ""),
          "gauge-#{index}-note" => to_string(row["note"] || "")
        })
      end)

    Map.merge(
      row_params,
      %{
        "block_id" => block["id"],
        "title" => to_string(block["title"] || ""),
        "mode" => "share",
        "max" => to_string(block["max"] || ""),
        "gauge-count" => to_string(length(rows))
      }
    )
    |> Map.merge(Map.new(overrides))
  end

  defp write_meta(params, view, request_id) do
    params
    |> Map.put("if_rev", socket_of(view).assigns.editor_doc.rev)
    |> Map.put("request_id", request_id)
  end

  defp create_document!(label, block) do
    id = "beta-gauge-list-#{label}-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(
        @doc_type,
        %{
          "doc_id" => id,
          "title" => "Gauge list",
          "content" => %{"blocks" => [block]}
        },
        @dataset
      )

    doc
  end

  defp mount_beta(conn, doc_id) do
    raw = "beta-gauge-list-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "Beta gauge-list editing", @dataset, ["read", "write"])
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    path = scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{doc_id}")
    {:ok, view, _html} = live(conn, path)

    html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert html =~ ~s(data-test-id="studio-doc-beta-editor")
    assert socket_of(view).assigns[:paper_doc] == nil
    {view, path}
  end

  defp stored_block(doc_id) do
    {:ok, doc} = Content.get_document(doc_id, @doc_type, @dataset)
    [block] = doc.content["blocks"]
    block
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
