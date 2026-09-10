defmodule BarkparkWeb.Studio.StudioAdminAffordanceGateTest do
  @moduledoc """
  task-ea341f86571c5981 — THE EDITOR MUST NOT ADVERTISE A DOOR THE SERVER HAS
  ALREADY DECIDED AGAINST.

  `schema_action`, `bulk-publish` and `bulk-unpublish` are `:admin`-tier in
  `Caps.classify/1` (arpss-schema-action-write-tier-ruling, #15902), so a
  WRITE-tier member is server-HALTED on all three. The editor rendered their
  buttons to that member anyway, so the only way to learn one's own authority
  was to click and be denied.

  ## Why both directions are asserted, in one test each

  A one-sided hide test proves nothing: a component that renders the buttons
  for NOBODY passes the hide half and is a regression. So every assertion below
  is paired — the same selector, the same mounted route, the same fixture, the
  only difference being the seat. The write-tier arm additionally asserts
  `caps == %{read: true, write: true, admin: false}` off the live socket, so a
  hidden button is provably the ADMIN tier talking rather than a missing write
  cap or a fixture that failed to load a document.

  ## Hidden is NOT denied

  This suite measures COSMETIC honesty only. The server-side halt is frozen and
  measured by `BarkparkWeb.Studio.StudioLiveCapsGateTest`'s
  "structural mutation is admin-tier, not write-tier" block, which this change
  does not touch.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "production"
  @admin "affordance-admin"
  @member "affordance-member"
  @type_name "affordanceart"
  @slug "affordance-doc"

  # A schema-declared `"modal"` action is the ONLY doc-action kind that emits
  # `phx-click="schema_action"` (`Editor.doc_action_button/1`).
  @modal_action %{
    "name" => "affordance_modal_action",
    "label" => "Structural Action",
    "kind" => "modal",
    "opts" => %{"class" => "btn btn-sm"},
    "modal" => %{"title" => "Structural Action", "body" => "Run it?"}
  }

  setup %{conn: conn} do
    {_ws, _proj} = TenancyFixtures.ensure_default_scope!()

    {:ok, _} = Auth.create_token(@admin, "affordance admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(@member, "affordance member", @dataset, ["read", "write"])

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Affordance Articles",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}],
          "actions" => [@modal_action]
        },
        @dataset
      )

    {:ok, doc} =
      Content.create_document(
        @type_name,
        %{"doc_id" => @slug, "title" => "Affordance Doc"},
        @dataset
      )

    Barkpark.SharingFixtures.clear_shares!()

    {:ok, conn: conn, doc_id: doc.doc_id}
  end

  # The reserved `["open", type, id]` nav path — resolves the document with no
  # structure lookup, so the editor is open for a reason unrelated to the seat.
  defp open_editor(conn, token, doc_id) do
    conn
    |> Plug.Test.init_test_session(%{"api_token" => token})
    |> live(scoped_studio("/d/#{@dataset}/studio/open/#{@type_name}/#{doc_id}"))
  end

  defp caps(view), do: :sys.get_state(view.pid).socket.assigns.caps

  describe "schema_action — the editor-header structural door" do
    test "a WRITE-tier member does NOT see it", %{conn: conn, doc_id: doc_id} do
      {:ok, view, html} = open_editor(conn, @member, doc_id)

      # NON-VACUITY, seat: this principal HAS write. Any hide below is the
      # admin tier talking.
      assert caps(view) == %{read: true, write: true, admin: false}

      # NON-VACUITY, fixture: the editor really is open and really rendered a
      # doc-action bar — so the refute measures ONE missing button, not a
      # missing editor.
      assert has_element?(view, ~s([data-test-id="duplicate-doc"])),
             "the classic doc-action bar must be present, or the refute below is vacuous"

      refute html =~ ~s(phx-click="schema_action")
      refute has_element?(view, ~s([phx-click="schema_action"]))
    end

    test "an ADMIN DOES see it", %{conn: conn, doc_id: doc_id} do
      {:ok, view, html} = open_editor(conn, @admin, doc_id)

      assert caps(view).admin == true
      assert html =~ ~s(phx-click="schema_action")
      assert has_element?(view, ~s([phx-click="schema_action"]))
    end
  end

  describe "bulk-publish / bulk-unpublish — the floating bulk bar" do
    test "a WRITE-tier member sees the bar but neither admin-tier button", %{
      conn: conn,
      doc_id: doc_id
    } do
      {:ok, view, _html} = open_editor(conn, @member, doc_id)
      assert caps(view) == %{read: true, write: true, admin: false}

      # `toggle-doc-checkbox` is :write-tier, so this member passes the gate and
      # the bar renders — the bar's own presence is the non-vacuity control for
      # the two refutes.
      render_hook(view, "toggle-doc-checkbox", %{"id" => doc_id})

      assert has_element?(view, ~s([data-test-id="bulk-action-bar"])),
             "the bulk bar must render for a write member, or the refutes below are vacuous"

      assert has_element?(view, ~s([data-test-id="bulk-clear"])),
             "bulk-clear is :none-tier and must survive for a non-admin"

      refute has_element?(view, ~s([data-test-id="bulk-publish"]))
      refute has_element?(view, ~s([data-test-id="bulk-unpublish"]))
    end

    test "an ADMIN sees BOTH admin-tier bulk buttons", %{conn: conn, doc_id: doc_id} do
      {:ok, view, _html} = open_editor(conn, @admin, doc_id)
      assert caps(view).admin == true

      render_hook(view, "toggle-doc-checkbox", %{"id" => doc_id})

      assert has_element?(view, ~s([data-test-id="bulk-action-bar"]))
      assert has_element?(view, ~s([data-test-id="bulk-publish"]))
      assert has_element?(view, ~s([data-test-id="bulk-unpublish"]))
    end
  end

  describe "the answer has ONE owner" do
    test "Caps.admin_affordance?/1 reads the derived caps map and fails closed" do
      assert BarkparkWeb.Studio.Caps.admin_affordance?(%{read: true, write: true, admin: true})
      refute BarkparkWeb.Studio.Caps.admin_affordance?(%{read: true, write: true, admin: false})
      refute BarkparkWeb.Studio.Caps.admin_affordance?(%{})
      refute BarkparkWeb.Studio.Caps.admin_affordance?(nil)
    end
  end
end
