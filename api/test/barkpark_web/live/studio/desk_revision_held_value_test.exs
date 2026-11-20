defmodule BarkparkWeb.Studio.DeskRevisionHeldValue.Refuse do
  @moduledoc false
  # Refuses an excerpt holding "HACK".
  def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt/1]}

  def halt(%{doc: doc}) do
    excerpt = (Map.get(doc, "content") || %{})["excerpt"]
    if is_binary(excerpt) and excerpt =~ "HACK", do: {:halt, "excerpt HACK"}, else: :ok
  end

  def halt(_), do: :ok
end

defmodule BarkparkWeb.Studio.DeskRevisionHeldValueTest do
  @moduledoc """
  task-2cad4946448ba07b (review-27801): a draft save the store refused holds
  its value in the form buffer (`RefusedSave`). A revision opened then is
  drawn from the revision's stored values, not the held one (the server
  half; the browser half is `__desk_locked_value.test.mjs`). Reload over a
  conflict is disabled exactly where the editor's guard refuses it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.DeskRevisionHeldValue.Refuse
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"
  @history ",changesInspectorTab=history,inspect=sanity%2Fstructure%2Fhistory"

  setup %{conn: conn} do
    prior = Barkpark.PluginEnv.capture()
    Barkpark.PluginEnv.put!([Refuse])
    on_exit(fn -> Barkpark.PluginEnv.restore(prior) end)

    n = System.unique_integer([:positive])
    type = "rev_held_#{n}"
    id = "rev-held-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Held",
          "visibility" => "public",
          "groups" => [
            %{"name" => "main", "title" => "Main", "default" => true},
            %{"name" => "side", "title" => "Side"}
          ],
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string", "group" => "main"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "string", "group" => "main"},
            %{"name" => "stage", "title" => "Stage", "type" => "string", "group" => "side"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Held", "content" => %{"excerpt" => "Old"}},
        @dataset
      )

    {:ok, _} = Content.publish_document(id, type, @dataset)

    {:ok, _} =
      Content.upsert_document(
        type,
        %{
          "doc_id" => Content.draft_id(id),
          "title" => "Held",
          "content" => %{"excerpt" => "Draft"}
        },
        @dataset
      )

    rev =
      id
      |> Content.list_revisions(type, @dataset, limit: 10)
      |> Enum.find(&(&1.action == "publish"))

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "rev-held-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "rev-held", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     desk: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{type};#{id}",
     type: type,
     id: id,
     rev: rev.id}
  end

  defp open(c, params \\ "") do
    {:ok, view, _} = live(c.conn, c.desk <> params)
    render_async(view, 5_000)
    view
  end

  defp mark(c), do: %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, c.id)}

  defp excerpt(view) do
    html = view |> element(~s(#editor-form input[name="doc[excerpt]"])) |> render()
    [_, value] = Regex.run(~r/\svalue="([^"]*)"/, html)
    value
  end

  test "a value a refused save holds is not drawn over the revision's stored value", c do
    view = open(c)

    view
    |> element("#editor-form")
    |> render_change(
      Map.merge(mark(c), %{
        "_target" => ["doc", "excerpt"],
        "doc" => %{"title" => "Held", "excerpt" => "NewHACK"}
      })
    )

    assert render(view) =~ "Not saved"
    assert excerpt(view) == "NewHACK"

    render_patch(view, c.desk <> @history <> ",rev=#{c.rev}")
    render_async(view, 5_000)
    assert excerpt(view) == "Old"

    render_patch(view, c.desk)
    render_async(view, 5_000)
    assert excerpt(view) == "NewHACK", "the live form keeps the held value"
  end

  describe "Reload over a conflict" do
    alias BarkparkWeb.Studio.Desk.ReadonlyFields

    @live %{desk_revision: nil, desk_published_view: nil}
    @revision %{id: "r1", form: %{}}
    @missing %{id: "nope", missing: true}
    @published %{form: %{}}

    test "is disabled exactly where the editor's guard refuses it" do
      refused? = &ReadonlyFields.refused?("reload-remote-doc", Map.merge(@live, &1))

      refute refused?.(%{})
      assert refused?.(%{desk_revision: @revision})
      assert refused?.(%{desk_published_view: @published})
      assert refused?.(%{desk_published_view: @published, desk_revision: @revision})

      # The published view over a URL naming a missing revision: no form is
      # drawn, the guard still refuses, so a Reload drawn there is disabled.
      assert refused?.(%{desk_published_view: @published, desk_revision: @missing})

      refute ReadonlyFields.readonly?(
               Map.merge(@live, %{desk_published_view: @published, desk_revision: @missing})
             )
    end
  end
end
