defmodule BarkparkWeb.Studio.ApiTesterLiveSchemaTenancyTest do
  @moduledoc """
  The API Tester's schema-browser reference pane is a LIST door, and it was the
  only read in the module that carried no tenancy scope.

  THE SHAPE. `ApiTesterLive` mounts in the `:scoped_studio` live_session, whose
  `LiveScope.:resolve` hook resolves and authorizes the workspace, project and
  dataset from the URL and assigns `current_workspace` / `current_project` — the
  carrier every other Studio read turns into opts via
  `BarkparkWeb.ScopeHelpers.scope_opts/1`. The schema browser called
  `Content.list_schemas/1` at ARITY ONE: no opts list exists at that call site,
  so no workspace key, no project key, no caller context. Its sibling in the
  Studio settings desk asks the identical question of the identical function as
  `list_schemas(dataset, include_global: true, workspace_id: ws_id)`.

  WHY THE `dataset` PATH SEGMENT IS NOT A FENCE. With no scope opts,
  `Content.resolve_read_dataset_id/2` falls back to the seeded DEFAULT
  project's dataset row; when that project has no dataset of this slug it
  returns nil and `Content.Schema.scope_schema_to_dataset/3` degrades to a bare
  `s.dataset == ^dataset` STRING filter. A dataset slug is per-project, so the
  SAME slug exists in every tenant that chose it — which is precisely why
  `Barkpark.Content.Scope` calls the dataset string the leaf discriminator and
  the workspace the envelope around it. The fixture below gives two workspaces
  the same dataset slug for that reason: nothing but `workspace_id` can tell
  them apart.

  WHAT LEAKED. The pane renders, for every row it gets back, the schema NAME,
  TITLE, visibility badge and full field shape — public and PRIVATE alike, with
  no `visible_schemas/2` clamp — plus two aggregates, `Public schemas (N)` and
  `Private schemas (N)`. So the foreign tenant's private type definitions AND
  the count of them reached a viewer of a different workspace's Studio.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # THE COLLIDING KEY: one dataset slug, present in BOTH tenants. Isolation can
  # only come from `workspace_id` — if the fixture gave each workspace its own
  # dataset slug the read would separate them by accident and a green here would
  # prove nothing.
  @dataset "apitester-tenancy-ds"

  @foreign_schema "foreigntenanttype"
  @foreign_title "FOREIGN-TENANT-PRIVATE-TYPE"
  @foreign_field "foreigntenantfield"

  @own_schema "owntenanttype"
  @own_title "OWN-TENANT-PUBLIC-TYPE"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    uid = System.unique_integer([:positive])

    {:ok, foreign_ws} =
      Tenancy.create_workspace(%{slug: "apitester-foreign-#{uid}", name: "ForeignWS"})

    {:ok, foreign_proj} =
      Tenancy.create_project(foreign_ws, %{slug: "foreign-proj", name: "ForeignProj"})

    {:ok, _} = Tenancy.create_dataset(foreign_proj, %{slug: @dataset, name: "ForeignDs"})

    {:ok, own_ws} = Tenancy.create_workspace(%{slug: "apitester-own-#{uid}", name: "OwnWS"})
    {:ok, own_proj} = Tenancy.create_project(own_ws, %{slug: "own-proj", name: "OwnProj"})
    {:ok, _} = Tenancy.create_dataset(own_proj, %{slug: @dataset, name: "OwnDs"})

    # The other tenant's PRIVATE type — the thing a viewer of `own_ws` must
    # never see: its name, its human title, its field shape, or its existence
    # as a number in the "Private schemas (N)" header.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @foreign_schema,
          "title" => @foreign_title,
          "visibility" => "private",
          "fields" => [%{"name" => @foreign_field, "title" => "Secret", "type" => "string"}]
        },
        @dataset,
        workspace_id: foreign_ws.id,
        project_id: foreign_proj.id
      )

    # The viewer's OWN type, so the permit direction below has something to
    # assert and the refutes cannot pass on an empty pane.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @own_schema,
          "title" => @own_title,
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Name", "type" => "string"}]
        },
        @dataset,
        workspace_id: own_ws.id,
        project_id: own_proj.id
      )

    raw = "apitester-tenancy-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "apitester-tenancy", "production", ["read", "write"], default_ws.id)

    # A member of `own_ws` ONLY — never of the foreign workspace.
    {:ok, _} = TenancyAuth.create_membership(own_ws.id, token.id, "member")

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, own_ws: own_ws, own_proj: own_proj}
  end

  test "SECURITY: the schema browser shows this workspace's types only — not a foreign tenant's private type, and not its COUNT",
       %{conn: conn, own_ws: own_ws, own_proj: own_proj} do
    # REACHABILITY PRECONDITION, asserted first and on its own: the mount really
    # does complete through the real router, the `:shared_studio_browser`
    # pipeline and the `:scoped_studio` on_mount chain. Without it a redirect to
    # /login would make every refute below pass for the wrong reason — the most
    # common way a fence test goes vacuous.
    {:ok, view, _html} =
      live(conn, "/w/#{own_ws.slug}/p/#{own_proj.slug}/d/#{@dataset}/studio/api-tester")

    # The reference pane is behind a nav click; `"select"` is a @readonly_event,
    # so this is exactly the interaction any admitted reader can perform.
    html = render_click(view, "select", %{"id" => "ref-schemas"})

    # SUBJECT EXISTS: the schema-browser pane really rendered. Asserted before
    # anything about its contents, so a renamed endpoint id cannot silently turn
    # the refutes into assertions about a pane that was never on the page.
    assert html =~ "Public schemas ("
    assert html =~ "Private schemas ("

    # PERMIT DIRECTION: the caller's OWN type is listed, so the read reached the
    # store and the refutes below are not passing on an empty result set.
    assert html =~ @own_schema
    assert html =~ @own_title

    refute html =~ @foreign_schema,
           "a foreign workspace's schema NAME reached this workspace's API Tester"

    refute html =~ @foreign_title,
           "a foreign workspace's schema TITLE reached this workspace's API Tester"

    refute html =~ @foreign_field,
           "a foreign workspace's schema FIELD SHAPE reached this workspace's API Tester"

    # THE AGGREGATE, not just the rows. A fenced list beside an unfenced count
    # still discloses the other tenant's existence and volume — and this header
    # is the only place the private tier is counted at all.
    assert html =~ "Private schemas (0)",
           "the private-schema COUNT still totals a foreign workspace's types"
  end
end
