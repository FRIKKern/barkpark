defmodule BarkparkWeb.Studio.StudioLiveSwitchWorkspaceOracleTest do
  @moduledoc """
  task-1829c2e22b31b2d6 — `Handlers.Scope.switch_workspace/2` answered a
  client-supplied workspace slug in TWO different ways:

    * no such workspace          -> unchanged socket, no word at all;
    * exists, but not reachable  -> "You do not have access to that workspace".

  `switch-workspace` carries the slug as a phx-value, so any signed-in Studio
  user could forge the event with guessed slugs and read which workspaces
  exist in other tenants off the difference. That is the existence oracle
  `Handlers.Shares.target_workspace_admits?/2` refuses and #20016 closed for
  `StudioChrome.open_scope/2`.

  THE RULING, pinned here: both arms answer ONE sentence that names both
  possibilities and never says which one it was. Neither arm may go quiet —
  the #19933 press-answer contract (`press_answer_refusal_word_test.exs`)
  moved the outcome word to the server, so a silent refusal is the defect
  that PR fixed.

  So this file reds in TWO directions:

    * the refused arm gets its own wording back — the NO EXISTENCE ORACLE test
      fails (the mutation this task's criterion 2 names);
    * either arm goes quiet — the per-arm "speaks" tests fail.

  "User-visible" is measured on every surface the press reaches: the flash
  assign, the rendered `role="alert"` banner (`Nav.studio_flash/1`), and the
  two witnesses the press-answer hook in `root.html.heex` settles on (a URL
  patch, an `aria-current` move). With neither witness moved, the hook's word
  is its evidence-free fallback — the same for both arms by construction —
  so equal witnesses mean an equal press-answer word.

  A positive control drives the SAME handler to success on the same view
  shape, so the refusal assertions are not measuring a dead handler.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"
  @refusal "Could not open that workspace — it does not exist, or you do not have access to it"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    ws_a = create_workspace!("swo-a-#{n}")
    {:ok, proj_a} = Tenancy.create_project_with_dataset(ws_a, %{name: "swo-pa-#{n}"})
    ws_b = create_workspace!("swo-b-#{n}")
    {:ok, proj_b} = Tenancy.create_project_with_dataset(ws_b, %{name: "swo-pb-#{n}"})
    foreign = create_workspace!("swo-foreign-#{n}")
    {:ok, _} = Tenancy.create_project_with_dataset(foreign, %{name: "swo-pf-#{n}"})

    raw = "swo-#{n}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "swo-member",
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
      foreign: foreign
    }
  end

  defp studio(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  defp flash_error(view), do: :sys.get_state(view.pid).socket.assigns.flash["error"]

  defp current_ws_slug(view), do: :sys.get_state(view.pid).socket.assigns.current_workspace.slug

  # The rendered error banner's text (`Nav.studio_flash/1`, role="alert"), or
  # nil — what a sighted user sees and a screen reader announces.
  defp alert_text(html) do
    case Regex.run(~r{class="flash flash-error"[^>]*role="alert"[^>]*>([^<]*)</div>}, html) do
      [_, text] -> String.trim(text)
      nil -> nil
    end
  end

  # The press-answer hook's second witness (`_paCurrentSig`).
  defp aria_current_sig(html) do
    ~r/aria-current="([^"]*)"/ |> Regex.scan(html) |> Enum.map(&List.last/1) |> Enum.sort()
  end

  # The hook's first witness. LiveViewTest has no refute_patched/2, so the
  # absence is taken by letting assert_patch/2 time out; the positive control
  # below shows the same probe DOES see a patch from this handler.
  defp patched?(view) do
    assert_patch(view, 100)
    true
  rescue
    ArgumentError -> false
    ExUnit.AssertionError -> false
  end

  # Mount on A, forge `switch-workspace` with `slug`, and return everything
  # the user gets back.
  defp press(ctx, slug) do
    {:ok, view, _} = live(ctx.conn, studio(ctx.ws_a, ctx.proj_a))
    before_html = render(view)

    html = render_change(view, "switch-workspace", %{"workspace" => slug})

    %{
      flash: flash_error(view),
      alert: alert_text(html),
      scope_moved?: current_ws_slug(view) != ctx.ws_a.slug,
      url_patched?: patched?(view),
      aria_current_moved?: aria_current_sig(before_html) != aria_current_sig(html)
    }
  end

  @speaks %{
    flash: @refusal,
    alert: @refusal,
    scope_moved?: false,
    url_patched?: false,
    aria_current_moved?: false
  }

  describe "both failed switches name themselves — with the SAME sentence" do
    test "an existing workspace the principal CANNOT reach speaks", ctx do
      got = press(ctx, ctx.foreign.slug)

      assert got == @speaks,
             "the refused switch is mute or worded apart from the not-found arm: #{inspect(got)}"
    end

    test "a workspace slug that does NOT EXIST speaks", ctx do
      got = press(ctx, "swo-no-such-ws-#{ctx.n}")

      assert got == @speaks,
             "a not-found switch does not answer the one refusal sentence: #{inspect(got)}"
    end

    test "NO EXISTENCE ORACLE: not-found and refused are indistinguishable", ctx do
      refused = press(ctx, ctx.foreign.slug)
      not_found = press(ctx, "swo-no-such-ws-#{ctx.n}")

      # PRECONDITION: the refused slug really names a workspace, and the
      # not-found one really does not — so the pair measures the two arms.
      assert %Tenancy.Workspace{} = Tenancy.get_workspace_by_slug(ctx.foreign.slug)
      assert is_nil(Tenancy.get_workspace_by_slug("swo-no-such-ws-#{ctx.n}"))

      # The two arms say byte-for-byte the same thing on every surface...
      assert refused == not_found,
             "switch_workspace/2 tells a refused workspace from a missing one — an existence oracle: " <>
               "refused=#{inspect(refused)} not_found=#{inspect(not_found)}"

      # ...and that same thing is the refusal sentence: two silences are
      # "equal" too, and that is the pre-#19933 mute refusal, not the ruling.
      assert refused.flash == @refusal,
             "both arms agree, but on silence or on another sentence: #{inspect(refused)}"
    end
  end

  describe "POSITIVE CONTROL — the same handler, the success side" do
    test "a reachable workspace switches, patches, and raises no error", ctx do
      {:ok, view, _} = live(ctx.conn, studio(ctx.ws_a, ctx.proj_a))

      render_change(view, "switch-workspace", %{"workspace" => ctx.ws_b.slug})

      assert assert_patch(view, 500) =~ "/w/#{ctx.ws_b.slug}/p/#{ctx.proj_b.slug}/"
      assert current_ws_slug(view) == ctx.ws_b.slug
      assert is_nil(flash_error(view))
    end
  end
end
