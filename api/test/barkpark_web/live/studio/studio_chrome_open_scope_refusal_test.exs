defmodule BarkparkWeb.StudioChromeOpenScopeRefusalTest do
  @moduledoc """
  task-e6e0fd116d810b69 — `StudioChrome.open_scope/2` answered every failed
  dataset pick, an AUTHORIZATION refusal included, with a closed menu and no
  word. `scope-open` is click-bound (`Studio.WorkspaceSwitcher`, the dataset
  column), so a user picking a workspace they cannot reach was left guessing.

  THE RULING, pinned here: ONE refusal sentence covers all five failure arms
  (workspace not found, workspace not reachable, project not found, dataset
  blank, dataset not in the project) plus a press missing a key. Not-found and
  refused MUST read identically — a distinct "you cannot reach that workspace"
  would tell a principal which guessed slugs exist (the existence-oracle
  reasoning `Handlers.Shares.target_workspace_admits?/2` records). The note
  above `open_scope/2` carries the full argument.

  So this file reds in TWO directions:

    * an arm goes quiet again (the old bare `_ -> assign(socket, :scope_menu,
      nil)` catch-all) — every refusal test below fails;
    * an arm is split into its own wording — "not found and refused are
      indistinguishable" fails, which is the oracle guard.

  A positive control drives the SAME path to success, so the refusal
  assertions are not measuring a dead handler.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"
  @menu_open ~s{aria-label="Switch workspace, project and dataset"}
  @refusal "Could not open that scope — it does not exist, or you do not have access to it"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    ws_a = create_workspace!("osr-a-#{n}")
    {:ok, proj_a} = Tenancy.create_project_with_dataset(ws_a, %{name: "osr-pa-#{n}"})
    ws_b = create_workspace!("osr-b-#{n}")
    {:ok, proj_b} = Tenancy.create_project_with_dataset(ws_b, %{name: "osr-pb-#{n}"})
    foreign = create_workspace!("osr-foreign-#{n}")
    {:ok, foreign_proj} = Tenancy.create_project_with_dataset(foreign, %{name: "osr-pf-#{n}"})

    raw = "osr-#{n}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "osr-member",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, token.id, "member")
    {:ok, _} = Tenancy.Auth.create_membership(ws_b.id, token.id, "member")

    %{
      conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
      n: n,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b,
      foreign: foreign,
      foreign_proj: foreign_proj
    }
  end

  defp studio(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  defp flash_error(view), do: :sys.get_state(view.pid).socket.assigns.flash["error"]

  # The text of the rendered error banner (`Nav.studio_flash/1`, role="alert"),
  # or nil when none is on the page — what a sighted user sees and a screen
  # reader announces.
  defp alert_text(html) do
    case Regex.run(~r{<div class="flash flash-error" role="alert"[^>]*>([^<]*)</div>}, html) do
      [_, text] -> String.trim(text)
      nil -> nil
    end
  end

  # Open the menu on A, press `scope-open` with `params`, and return what the
  # user got: the flash, the banner, whether the menu is still open.
  defp press(ctx, params) do
    {:ok, view, _} = live(ctx.conn, studio(ctx.ws_a, ctx.proj_a))

    # PRECONDITION: the menu really is open before the press, so "closed after"
    # measures the press and not a menu that never opened.
    assert render_click(view, "scope-menu-toggle", %{}) =~ @menu_open

    html = render_click(view, "scope-open", params)

    refute_redirected(view)

    %{
      flash: flash_error(view),
      alert: alert_text(html),
      menu_open?: html =~ @menu_open
    }
  end

  @speaks %{flash: @refusal, alert: @refusal, menu_open?: false}

  describe "every failed pick names itself — with the SAME sentence" do
    test "an UNREACHABLE workspace (the authorization refusal) speaks", ctx do
      got =
        press(ctx, %{
          "ws" => ctx.foreign.slug,
          "proj" => ctx.foreign_proj.slug,
          "ds" => @dataset
        })

      assert got == @speaks,
             "the click-bound authorization refusal is mute again, or worded apart from the other arms: #{inspect(got)}"
    end

    test "a workspace that does NOT EXIST speaks", ctx do
      got =
        press(ctx, %{"ws" => "osr-no-such-ws-#{ctx.n}", "proj" => "x", "ds" => @dataset})

      assert got == @speaks,
             "a not-found workspace does not answer the one refusal sentence: #{inspect(got)}"
    end

    test "NO EXISTENCE ORACLE: not-found and refused are indistinguishable", ctx do
      refused =
        press(ctx, %{
          "ws" => ctx.foreign.slug,
          "proj" => ctx.foreign_proj.slug,
          "ds" => @dataset
        })

      not_found =
        press(ctx, %{
          "ws" => "osr-no-such-ws-#{ctx.n}",
          "proj" => ctx.foreign_proj.slug,
          "ds" => @dataset
        })

      # Both must SPEAK (two nils are "indistinguishable" too, and that is the
      # old silence, not the ruling)...
      assert refused.flash == @refusal
      # ...and say byte-for-byte the same thing. Giving the refusal its own
      # wording tells a principal that the slug it guessed exists.
      assert refused == not_found,
             "open_scope/2 now tells a refused workspace from a missing one — an existence oracle: " <>
               "refused=#{inspect(refused)} not_found=#{inspect(not_found)}"
    end

    test "a project not in the (reachable) workspace speaks the same sentence", ctx do
      # proj_a belongs to A; claiming it under B fails containment.
      got = press(ctx, %{"ws" => ctx.ws_b.slug, "proj" => ctx.proj_a.slug, "ds" => @dataset})

      assert got == @speaks,
             "a project-not-found pick does not answer the one refusal sentence: #{inspect(got)}"
    end

    test "a blank dataset speaks the same sentence", ctx do
      got = press(ctx, %{"ws" => ctx.ws_b.slug, "proj" => ctx.proj_b.slug, "ds" => ""})

      assert got == @speaks,
             "a blank-dataset pick does not answer the one refusal sentence: #{inspect(got)}"
    end

    test "a dataset not in the project speaks the same sentence", ctx do
      got = press(ctx, %{"ws" => ctx.ws_b.slug, "proj" => ctx.proj_b.slug, "ds" => "no-such-ds"})

      assert got == @speaks,
             "a dataset-not-in-project pick does not answer the one refusal sentence: #{inspect(got)}"
    end

    test "a press missing a key speaks the same sentence", ctx do
      # The switcher omits phx-value-ws when the menu has no workspace, so this
      # shape is reachable by a click, not only by a forged event.
      got = press(ctx, %{"proj" => ctx.proj_b.slug, "ds" => @dataset})

      assert got == @speaks,
             "a key-less pick does not answer the one refusal sentence: #{inspect(got)}"
    end
  end

  describe "POSITIVE CONTROL — the same path speaks on the success side" do
    test "a reachable triple navigates and raises no error", ctx do
      {:ok, view, _} = live(ctx.conn, studio(ctx.ws_a, ctx.proj_a))
      assert render_click(view, "scope-menu-toggle", %{}) =~ @menu_open

      # The success arm closes the menu and push_navigates; the navigation
      # takes the whole page (menu included) away, which is the answer.
      assert {:error, {:live_redirect, %{to: to}}} =
               render_click(view, "scope-open", %{
                 "ws" => ctx.ws_b.slug,
                 "proj" => ctx.proj_b.slug,
                 "ds" => @dataset
               })

      assert to == studio(ctx.ws_b, ctx.proj_b)
      assert_redirect(view, studio(ctx.ws_b, ctx.proj_b))
    end
  end
end
