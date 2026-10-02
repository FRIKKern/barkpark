defmodule BarkparkWeb.Studio.PaperCanvasHaltResyncTest do
  @moduledoc """
  A canvas batch the hollow ratchet REFUSES must not leave view and storage
  apart (Run-4 Lane B, routed from Lane C's dogfood).

  Repro: new paper → type five lines → Cmd+Z once. The local undo empties the
  body, the canvas sends the batch, the server refuses it with the D3 ratchet
  ("a published paper cannot be hollowed out") — and the reply was a bare
  `%{saved: false}`. The canvas kept showing an empty paper; storage kept the
  text; a reload "brought it back".

  The ratchet itself is the D3 ruling and is NOT touched here: the same batch
  is still refused and storage still holds the text. What changes is the
  reply, which is contract-neutral for every other caller:

    * `rejected: "halted"` + the server's `reason`, verbatim (D5/D6 — the editor
      authors no copy);
    * the STORED canvas `runs`, so the host can put the run back on storage.

  The host half (drop the refused batch, apply the stored run, surface the
  reason) is pinned by `api/assets/paper-editor/src/__halt_resync.test.mjs`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.Papers.Hollow

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    slug = "halt-resync-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          blocks: [
            %{
              "id" => "b-body",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Five lines of real prose."}]
            }
          ]
        })
      )

    raw = "halt-resync-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(
        raw,
        "halt-resync",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    %{slug: slug, conn: Plug.Test.init_test_session(scoped_conn(), %{"api_token" => raw})}
  end

  defp canvas_context(view, slug) do
    {:ok, doc} = Content.get_document(slug, "paper", @dataset)
    ids = doc.content["blocks"] |> Content.ensure_block_ids() |> Enum.map(& &1["id"])

    %{
      "if_rev" => :sys.get_state(view.pid).socket.assigns.paper_rev,
      "container_kind" => "document",
      "container_run_ids" => ids
    }
  end

  defp stored_text(slug) do
    {:ok, doc} = Content.get_document(slug, "paper", @dataset)
    Jason.encode!(doc.content["blocks"])
  end

  test "a hollowing batch is refused with its reason and the stored runs", %{
    conn: conn,
    slug: slug
  } do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))
    request_id = Ecto.UUID.generate()

    render_hook(
      view,
      "paper-ops",
      Map.merge(canvas_context(view, slug), %{
        "request_id" => request_id,
        "ops" => [%{"op" => "patch-block", "id" => "b-body", "patch" => %{"content" => []}}]
      })
    )

    # D3 unchanged: the server still refuses and storage keeps the prose.
    assert stored_text(slug) =~ "Five lines of real prose."

    assert_reply(view, %{saved: false, request_id: ^request_id} = reply)

    assert reply[:rejected] == "halted",
           "the refusal reply carries no reason code: #{inspect(reply)}"

    assert reply[:reason] == Hollow.ratchet_message()

    runs = reply[:runs] || []
    assert runs != [], "the refusal reply carries no stored runs to resync to"

    assert Enum.any?(runs, fn run ->
             is_binary(run.run_id) and Jason.encode!(run.blocks) =~ "Five lines of real prose."
           end),
           "the stored runs do not hold the stored prose"
  end

  test "an accepted batch is unaffected (no rejected/runs keys)", %{conn: conn, slug: slug} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))
    request_id = Ecto.UUID.generate()

    render_hook(
      view,
      "paper-ops",
      Map.merge(canvas_context(view, slug), %{
        "request_id" => request_id,
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "b-body",
            "patch" => %{"content" => [%{"type" => "text", "value" => "Edited prose."}]}
          }
        ]
      })
    )

    assert_reply(view, %{saved: true, request_id: ^request_id} = reply)
    refute Map.has_key?(reply, :rejected)
    assert stored_text(slug) =~ "Edited prose."
  end
end
