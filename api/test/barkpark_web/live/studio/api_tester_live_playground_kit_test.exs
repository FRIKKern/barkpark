defmodule BarkparkWeb.Studio.ApiTesterLivePlaygroundKitTest do
  @moduledoc """
  Markup-pinning coverage for the API-tester playground after it moved onto the
  StudioComponents.Controls kit (sup-w3-api-tester-kit).

  The three existing api_tester test files pin behavior only (authz, scope
  guard, plugin asserts) and say nothing about the rendered controls — so the
  kit conversion (native `<select>`/`<input>`/`<textarea>` → `bp_select`/
  `bp_input`/`bp_textarea`) had ZERO regression net. This file renders the real
  playground and asserts:

    * query params render the themed kit — no class-less native control leaks;
    * a `:select` query param renders `bp_select` with the CURRENT value marked
      `selected` (value-match semantics preserved through the kit);
    * a POST body renders `bp_textarea` still carrying the `api-body-textarea`
      sizing class AND `spellcheck="false"` — the exact passthrough the additive
      `bp_textarea` `class`/`spellcheck` extension exists to keep. A plain
      LiveViewTest cannot "see" a dropped sizing class visually; this pins it.

  The scenario-results block (the sub-AA fix site) is NOT asserted here — it only
  renders after an admin `run-all` fans out real HTTP. Its AA escalation is
  proven by the design/check.mjs Part H rows, not a render assert.

  Scope/setup mirrors ApiTesterLiveAuthzTest: a uniquely-slugged
  workspace+project+dataset mounted at its scoped API Tester URL.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @ws_slug "api-tester-kit-ws"
  @proj_slug "api-tester-kit-proj"
  @dataset "api-tester-kit-ds"

  setup do
    default_ws = Tenancy.get_default_workspace()

    {:ok, ws} = Tenancy.create_workspace(%{slug: @ws_slug, name: "ApiTesterKitWS"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: @proj_slug, name: "ApiTesterKitProj"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "ApiTesterKit"})

    admin_raw = "api-tester-kit-admin-" <> Ecto.UUID.generate()

    {:ok, admin_tok} =
      Auth.create_token(admin_raw, "kit-admin", "production", ~w(read write admin), default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, admin_tok.id, "admin")

    {:ok, admin_raw: admin_raw}
  end

  defp mount_as(conn, raw) do
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    live(conn, "/w/#{@ws_slug}/p/#{@proj_slug}/d/#{@dataset}/studio/api-tester")
  end

  describe "playground rides the Controls kit" do
    test "a :select query param renders bp_select — themed, value-match selected, no class-less native select",
         %{conn: conn, admin_raw: raw} do
      {:ok, view, _html} = mount_as(conn, raw)

      # List documents (GET) carries a `perspective` :select query param.
      html = render_click(view, "select", %{"id" => "query-list"})

      # The kit renders a themed select — every playground <select> carries the
      # form-input class (no native, unthemed dropdown leaks through).
      assert html =~ ~s(name="perspective")
      refute html =~ ~r/<select name="perspective"(?![^>]*class="form-input")/

      # Value-match selected is preserved through the kit: the seeded default
      # ("published") is the marked option.
      assert html =~ ~r/<option value="published"[^>]*selected/

      # bp_input drives the text/path params — the mono-height override rides the
      # parent `.api-param-row .form-input` selector, so the base class survives.
      assert html =~ ~s(name="type")
      refute html =~ ~r/<input name="type"[^>]*type="text"(?![^>]*form-input)/

      # The `token-change` handler is NOT orphaned: the top-bar Token field
      # (layouts/studio.html.heex, shown while nav_section == :api_tester)
      # dispatches it, so the handler must stay. Pin the live wiring.
      assert html =~ ~s(phx-change="token-change")
      assert html =~ ~s(name="token")
    end

    test "a POST body renders bp_textarea keeping api-body-textarea + spellcheck=false",
         %{conn: conn, admin_raw: raw} do
      {:ok, view, _html} = mount_as(conn, raw)

      # Create document (POST) renders the JSON body textarea.
      html = render_click(view, "select", %{"id" => "mutate-create"})

      assert html =~ ~s(name="_body_text")
      # The additive bp_textarea class passthrough kept the sizing/idiom class on
      # top of the themed base — a silent drop here would be invisible visually.
      assert html =~ ~s(class="form-input api-body-textarea")
      # spellcheck rides the :rest include list.
      assert html =~ ~s(spellcheck="false")
    end
  end
end
