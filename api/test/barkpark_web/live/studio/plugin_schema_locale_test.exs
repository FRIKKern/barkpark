defmodule BarkparkWeb.Studio.PluginSchemaLocaleTest do
  @moduledoc """
  task-0ded99e28e620ba5, ruling (a): a content plugin's schema chrome reads in
  the Studio language. In an nb-NO workspace the Quiz editor's fields read
  "Title", "Question prompt", "Time limit (seconds)", "Choices" in English.
  Studio now translates a plugin schema's own titles when it opens it
  (`PluginSchemaCopy`); the stored schema stays English, an unmarked title stays
  as written, and an English workspace reads as before.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.PluginSchemaCopy

  @dataset "production"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "quiz-loc-#{suffix}", name: "Quiz Locale"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    raw = "quiz-loc-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "quiz-loc", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    scope = [workspace_id: ws.id, project_id: proj.id]
    quiz = Barkpark.Quiz.Content.schema()

    # An operator renamed one field: their title is not a marked string, so it
    # stays as written.
    fields =
      Enum.map(quiz.fields, fn
        %{"name" => "image"} = f -> Map.put(f, "title", "Bilde til spørsmålet")
        f -> f
      end)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => quiz.name,
          "title" => quiz.title,
          "visibility" => "public",
          "fields" => fields
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "quiz",
        %{"doc_id" => "quiz-loc-1", "title" => "Fjellquiz"},
        @dataset,
        scope
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp editor_html(conn, ws, proj) do
    {:ok, view, _} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/quiz/quiz-loc-1")

    view |> element(".editor-panel") |> render()
  end

  test "a Norwegian Quiz editor reads Norwegian field titles", %{conn: conn, ws: ws, proj: proj} do
    html = editor_html(conn, ws, proj)

    for word <- ["Tittel", "Spørsmål", "Tidsgrense (sekunder)", "Svaralternativer"] do
      assert html =~ word, "expected #{inspect(word)} in the nb-NO Quiz editor"
    end

    for english <- ["Question prompt", "Time limit (seconds)", ">Choices<"] do
      refute html =~ english
    end

    # The operator's own title is left as they wrote it.
    assert html =~ "Bilde til spørsmålet"
  end

  test "an English Quiz editor reads as before", %{conn: conn, ws: ws, proj: proj} do
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "en")
    html = editor_html(conn, ws, proj)

    assert html =~ "Question prompt"
    assert html =~ "Time limit (seconds)"
  end

  test "every Quiz, Forms and paper-form schema string has a translation marker" do
    forms =
      Barkpark.Plugins.Forms.register_schemas(dataset: @dataset)
      |> Enum.filter(&(&1.name in PluginSchemaCopy.schemas()))

    form_response =
      Path.expand("../../../../priv/plugins/bulldocs/schemas/form_response.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> then(&%{name: &1["name"], title: &1["title"], fields: &1["fields"]})

    schemas = [Barkpark.Quiz.Content.schema(), form_response | forms]
    assert Enum.map(schemas, & &1.name) |> Enum.sort() == Enum.sort(PluginSchemaCopy.schemas())

    strings =
      schemas
      |> Enum.flat_map(fn s -> [s.title | Enum.flat_map(s.fields, &titles/1)] end)
      |> Enum.uniq()

    assert strings -- PluginSchemaCopy.markers() == []
  end

  test "localize/1 leaves a schema that no content plugin owns unchanged" do
    schema = %{name: "article", title: "Title", fields: [%{"name" => "t", "title" => "Title"}]}

    assert Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
             PluginSchemaCopy.localize(schema)
           end) == schema
  end

  defp titles(%{} = f) do
    own = for k <- ["title", "description"], is_binary(f[k]), do: f[k]

    nested =
      case f["of"] do
        %{} = one -> titles(one)
        list when is_list(list) -> Enum.flat_map(list, &titles/1)
        _ -> []
      end

    own ++ nested ++ Enum.flat_map(f["fields"] || [], &titles/1)
  end
end
