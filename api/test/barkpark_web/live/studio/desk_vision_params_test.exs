defmodule BarkparkWeb.Studio.DeskVisionParamsTest do
  @moduledoc """
  The desk's Vision has Params, as TanStack's (J37, `vision-saved.spec.ts`):
  a JSON object under the query, whose keys the query names as `$key`. The
  script sends each as `$key=<JSON>` to the same GROQ read
  (`__desk_vision.test.mjs` §8); here, the pane is drawn with its words in
  nb_NO too, and the read keeps the path's dataset whatever a parameter
  says.
  """
  use BarkparkWeb.ConnCase, async: false
  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.TenancyFixtures

  @dataset "production"

  defp signed_in(workspace) do
    raw = "dvq-token-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "dvq", @dataset, ["read", "write", "admin"], workspace.id)
    Plug.Test.init_test_session(scoped_conn(), %{"api_token" => raw})
  end

  test "Params sits under the query: a labelled box holding an empty object, its error icon hidden" do
    {ws, proj} = TenancyFixtures.ensure_default_scope!()
    vision = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/_tools/vision"
    {:ok, view, html} = live(signed_in(Tenancy.get_default_workspace()), vision)

    assert has_element?(
             view,
             ~s{.dk-vision-query [data-vision-params-pane] label[for="vision-params"]},
             "Params"
           )

    assert has_element?(view, ~s{textarea#vision-params[data-vision-params][spellcheck="false"]})

    assert has_element?(
             view,
             ~s{[data-vision-params-error][hidden][role="img"][aria-label="Parameters are not valid JSON"]}
           )

    box = html |> LazyHTML.from_document() |> LazyHTML.query("#vision-params") |> LazyHTML.text()
    assert box == "{\n  \n}"

    root = html |> LazyHTML.from_document() |> LazyHTML.query("#dk-vision")
    at = fn name -> root |> LazyHTML.attribute(name) |> List.first() end
    assert at.("data-t-params-json") == "Parameters are not valid JSON: %{detail}"
    assert at.("data-t-params-object") == ~s(Params must be a JSON object, like {"title": "post"})
    assert at.("data-t-params-missing") == "Param $%{name} referenced, but not provided"
  end

  test "the Params words are in nb_NO" do
    nb = fn -> Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn -> words() end) end

    assert nb.() == [
             "Parametre",
             "Parametrene er ikke gyldig JSON",
             "Parametrene er ikke gyldig JSON: x",
             ~s(Parametrene må være et JSON-objekt, som {"title": "post"}),
             "Parameteren $id er brukt, men ikke gitt"
           ]
  end

  defp words do
    [
      gettext("Params"),
      gettext("Parameters are not valid JSON"),
      gettext("Parameters are not valid JSON: %{detail}", detail: "x"),
      gettext(~s(Params must be a JSON object, like {"title": "post"})),
      gettext("Param $%{name} referenced, but not provided", name: "id")
    ]
  end

  test "a parameter never changes the dataset the GROQ read answers from", %{conn: conn} do
    tag = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "dvq-ws-#{tag}", name: "DVQ"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]
    other = "dvq-other-#{tag}"

    for {ds, id} <- [{@dataset, "here"}, {other, "there"}] do
      schema = %{"name" => "post", "title" => "post", "visibility" => "public", "fields" => []}
      {:ok, _} = Content.upsert_schema(schema, ds, scope)
      {:ok, _} = Content.create_document("post", %{"_id" => id, "title" => id}, ds, scope)
      {:ok, _} = Content.publish_document(id, "post", ds, scope)
    end

    token = "dvq-#{tag}"
    {:ok, _} = Auth.create_token(token, "dvq", @dataset, ["read"], ws.id)

    # What the script sends for Params {"t": "post", "dataset": "<other>"}, and a bare
    # dataset= beside it: the path's dataset answers.
    body =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/w/#{ws.slug}/p/site/v2025-02-19/data/query/#{@dataset}", %{
        "query" => "*[_type == $t]{_id}",
        "$t" => ~s("post"),
        "$dataset" => Jason.encode!(other),
        "dataset" => other,
        "perspective" => "published"
      })
      |> json_response(200)

    assert body["result"] == [%{"_id" => "here"}]
  end
end
