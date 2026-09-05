defmodule BarkparkWeb.PublicPaperStructuredControlsTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}

  @dataset "production"

  setup %{conn: conn} do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    {:ok, _} =
      Content.Codelists.register("onixedit", "onixedit:list_15", %{
        issue: "73",
        name: "Title type",
        values: [
          %{code: "01", translations: [%{language: "eng", label: "Distinctive title"}]},
          %{code: "05", translations: [%{language: "eng", label: "Abbreviated title"}]}
        ]
      })

    slug = "public-structured-controls-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          blocks: structured_blocks()
        })
      )

    %{conn: writer_conn(conn), slug: slug}
  end

  test "public structured controls persist real form and reorder interactions across reload", %{
    conn: conn,
    slug: slug
  } do
    {:ok, view, _html} = live(conn, "/papers/#{slug}")
    edit_html = render_click(view, "paper-toggle-edit", %{})

    for {id, type} <- [
          {"public-price", "composite"},
          {"public-keywords", "arrayOf"},
          {"public-title-type", "codelist"},
          {"public-blurb", "localizedText"}
        ] do
      assert edit_html =~ ~s(id="paper-fb-#{id}")
      assert edit_html =~ ~s(data-field-type="#{type}")
    end

    change_form(view, "public-price", %{"amount" => "349", "currency" => "SEK"})
    change_form(view, "public-blurb", %{"eng" => "Fresh English", "nob" => "Ny norsk"})
    change_form(view, "public-title-type", %{"value" => "05"})

    view
    |> element(
      ~s([data-block-id="public-keywords"] button[phx-value-action="move_up"][phx-value-index="1"])
    )
    |> render_click()

    render(view)

    view
    |> element(~s([phx-hook="BarkparkPaperCanvas"]))
    |> render_hook("paper-ops", %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => current_rev(view),
      "ops" => [
        %{
          "op" => "patch-block",
          "id" => "public-reference",
          "patch" => %{"value" => "target-paper"}
        }
      ]
    })

    assert stored_value(slug, "public-price") == %{"amount" => "349", "currency" => "SEK"}
    assert stored_value(slug, "public-blurb") == %{"eng" => "Fresh English", "nob" => "Ny norsk"}
    assert stored_value(slug, "public-title-type") == "05"
    assert stored_value(slug, "public-keywords") == ["norway", "history"]
    assert stored_value(slug, "public-reference") == "target-paper"

    {:ok, reloaded, _html} = live(conn, "/papers/#{slug}")
    render_click(reloaded, "paper-toggle-edit", %{})

    assert has_element?(
             reloaded,
             ~s([data-block-id="public-price"] input[name="amount"][value="349"])
           )

    assert has_element?(
             reloaded,
             ~s([data-block-id="public-price"] input[name="currency"][value="SEK"])
           )

    assert reloaded
           |> element(~s([data-block-id="public-blurb"] textarea[name="eng"]))
           |> render() =~ "Fresh English"

    assert has_element?(
             reloaded,
             ~s([data-block-id="public-title-type"] option[value="05"][selected])
           )

    assert has_element?(
             reloaded,
             ~s([data-block-id="public-keywords"] input[name="[0]"][value="norway"])
           )

    assert reloaded_canvas_block(reloaded, "public-reference") == %{
             "id" => "public-reference",
             "type" => "field-reference",
             "label" => "Related paper",
             "fieldName" => "relatedPaper",
             "refType" => "paper",
             "dataset" => @dataset,
             "value" => "target-paper"
           }
  end

  defp structured_blocks do
    [
      %{
        "id" => "public-price",
        "type" => "composite",
        "label" => "Price",
        "fields" => [
          %{"name" => "amount", "title" => "Amount", "type" => "string"},
          %{"name" => "currency", "title" => "Currency", "type" => "string"}
        ],
        "value" => %{"amount" => "299", "currency" => "NOK"}
      },
      %{
        "id" => "public-keywords",
        "type" => "arrayOf",
        "label" => "Keywords",
        "ordered" => true,
        "of" => %{"name" => "keyword", "type" => "string"},
        "value" => ["history", "norway"]
      },
      %{
        "id" => "public-title-type",
        "type" => "codelist",
        "label" => "Title type",
        "plugin" => "onixedit",
        "codelistId" => "onixedit:list_15",
        "version" => 73,
        "variant" => "flat",
        "value" => "01"
      },
      %{
        "id" => "public-blurb",
        "type" => "localizedText",
        "label" => "Blurb",
        "languages" => ["nob", "eng"],
        "format" => "plain",
        "fallbackChain" => ["nob", "eng"],
        "value" => %{"nob" => "Omtale", "eng" => "Blurb"}
      },
      %{
        "id" => "public-reference",
        "type" => "field-reference",
        "label" => "Related paper",
        "fieldName" => "relatedPaper",
        "refType" => "paper",
        "dataset" => @dataset,
        "value" => ""
      }
    ]
  end

  defp change_form(view, block_id, values) do
    view
    |> element(~s([data-block-id="#{block_id}"] form))
    |> render_change(values)

    render(view)
  end

  defp stored_value(slug, id) do
    slug
    |> Content.paper_blocks(@dataset)
    |> Enum.find(&(&1["id"] == id))
    |> Map.fetch!("value")
  end

  defp current_rev(view), do: :sys.get_state(view.pid).socket.assigns.paper_rev

  defp reloaded_canvas_block(view, id) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s([phx-hook="BarkparkPaperCanvas"]))
    |> LazyHTML.attribute("data-canvas-blocks")
    |> Enum.flat_map(&Jason.decode!/1)
    |> Enum.find(&(&1["id"] == id))
  end

  defp writer_conn(conn) do
    raw = "public-structured-writer-#{System.unique_integer([:positive])}"

    {:ok, _token} =
      Auth.create_token(raw, "public structured writer", @dataset, ["read", "write"])

    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end
end
