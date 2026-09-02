defmodule BarkparkWeb.SheetsM4ProofTest do
  @moduledoc """
  PROOF story for Sheets M4 — the full multiplayer arc, independent of the
  builders' suites: Kari and Ola edit the launch budget together in two
  Studio LiveViews while a third, unauthenticated public reader mount on
  the published `/sheets/:slug` watches every change live.

  The beats, in order: Kari's click lands her colored cursor + name tag on
  C3 in Ola's pane; Ola's B2:D5 selection paints the translucent overlay in
  his deterministic color on Kari's; Kari's edit-start raises the
  emphasized editing tag (the visual soft lock) and her 4200 commit clears
  it while landing on Ola's grid; Ola's `=C3*2` formula computes 8400 on
  Kari's; Kari's Cmd+Z (the hook's "undo" event) reverts her 4200 on BOTH
  screens — C3 back to the seeded 2100, D3 recomputed to 4200 — and
  Cmd+Shift+Z redoes it; the public reader stays pinned to PUBLISHED content (drafts never leak)
  live and carries zero edit affordances; Ola's process death removes his
  cursor with no ghost presence entries. Colors differ per user_id, names
  render, self is never a peer.

  `async: false` — sheet sessions are globally registered processes and
  presence diffs fan out across test-spawned LiveViews, same as the M2/M4
  suites.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PresenceState

  @dataset "production"
  @slug "launch-budget-m4-proof"
  @kari_id "kari-budget"
  @ola_id "ola-budget"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    # The public reader resolves within the seeded Default workspace.
    Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sheet",
          "title" => "Sheets",
          "icon" => "grid",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    :ok
  end

  defp put_cfg(overrides) do
    base = Application.get_env(:barkpark, Barkpark.Plugins.Sheets.Session, [])

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.Sheets.Session,
      Keyword.merge(base, overrides)
    )
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # Mount Studio on the sheet AS a specific identity — the same localStorage
  # connect params the studio in-bar presence reads.
  defp open_as!(slug, user_id, user_name) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> put_connect_params(%{"user_id" => user_id, "user_name" => user_name})

    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{slug}"))
    {view, with_target(view, "#sheet-grid-#{slug}"), html}
  end

  defp cell(view, ref) do
    view |> element(~s(td[data-ref="#{ref}"])) |> render()
  end

  # Peer decoration lives on the overlay layer (one box per cursor, one
  # rect per selection), never on the tds — see the SheetGrid moduledoc.
  # Missing boxes render as "" so `eventually` retries instead of raising.
  defp peer_cursor(view, ref) do
    selector = ~s(.sheet-peer-cursor[data-peer-cell="#{ref}"])
    if has_element?(view, selector), do: view |> element(selector) |> render(), else: ""
  end

  # A peer's NAME is rendered in exactly one place: the `.sheet-peer-tag`
  # span inside the presence overlay ([data-test-id="sheet-peer-layer"],
  # sheet_grid.ex peer_layer/1), and the whole layer disappears once the
  # last peer leaves. Refuting a short name against the WHOLE rendered
  # document is therefore a coin flip, not a check: the document also
  # carries LiveView's random base64url root id, and `phx-GMYBobnrrpWUuvZB`
  # contains the literal substring "Bob" — one such draw red-flagged a PR
  # that never touched sheets. Scope every peer-NAME refutation to this
  # helper; class-name refutations ("sheet-peer-tag", "sheet-peer-editing")
  # carry no collision risk and stay whole-document, which is stronger.
  # Absent layer renders as "" so `eventually` retries instead of raising.
  defp peer_layer(view) do
    selector = ~s([data-test-id="sheet-peer-layer"])
    if has_element?(view, selector), do: view |> element(selector) |> render(), else: ""
  end

  defp peer_selection(view, range) do
    selector = ~s(.sheet-peer-sel[data-peer-range="#{range}"])
    if has_element?(view, selector), do: view |> element(selector) |> render(), else: ""
  end

  # The selection rect paints a translucent rgba() fill derived from the
  # peer's palette hex — same conversion the component applies.
  defp overlay_rgba("#" <> hex) do
    [r, g, b] = for i <- [0, 2, 4], do: hex |> String.slice(i, 2) |> String.to_integer(16)
    "rgba(#{r}, #{g}, #{b}, 0.12)"
  end

  # Presence diffs (Phoenix.Tracker) and LV re-renders are asynchronous —
  # retry the assertion briefly instead of sleeping a fixed eternity.
  defp eventually(fun, tries \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, tries) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      eventually(fun, tries - 1)
  end

  test "Kari and Ola edit the launch budget together while a public dashboard watches" do
    # The launch budget exists with a label column and last quarter's venue
    # figure in C3 — and it is PUBLISHED, so the public dashboard can watch.
    {:ok, _} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => @slug,
          "title" => "Launch budget",
          "content" => %{
            "tabs" => [
              %{
                "name" => "Budget",
                "cells" => %{
                  "A3" => %{"v" => "Venue"},
                  "C3" => %{"v" => 2100, "t" => "n"},
                  "A5" => %{"v" => "Catering"}
                }
              }
            ]
          }
        },
        @dataset
      )

    {:ok, _} = Content.publish_document(@slug, "sheet", @dataset)

    # ── the public dashboard mounts FIRST and will watch everything ────────
    {:ok, reader, reader_html} = live(Phoenix.ConnTest.build_conn(), "/sheets/#{@slug}")
    assert reader_html =~ ~s(data-test-id="sheet-reader-head")
    assert reader_html =~ "Launch budget"
    assert cell(reader, "C3") =~ ~s(data-v="2100")

    # ── Kari and Ola open the sheet in Studio ──────────────────────────────
    {kari, kari_grid, _} = open_as!(@slug, @kari_id, "Kari")
    {ola, ola_grid, _} = open_as!(@slug, @ola_id, "Ola")

    kari_color = PresenceState.pick_color(@kari_id)
    ola_color = PresenceState.pick_color(@ola_id)

    # Payload hygiene, up front: two users, two DIFFERENT deterministic
    # palette colors — same user_id always maps to the same color.
    assert kari_color != ola_color
    assert kari_color == PresenceState.pick_color(@kari_id)

    # ── 1. Kari clicks C3 — Ola sees her cursor + name tag land there ──────
    # The click sets the active cell; the hook's throttled presence frame
    # carries it onto the wire (exactly what bp-sheet-grid.js emits).
    render_hook(kari_grid, "cell-click", %{"ref" => "C3", "shift" => false})
    render_hook(kari_grid, "presence-meta", %{"active" => "C3", "selection" => nil})

    eventually(fn ->
      c3 = peer_cursor(ola, "C3")
      assert c3 =~ "sheet-peer-cursor"
      assert c3 =~ "Kari"
      assert c3 =~ "background: #{kari_color}"
    end)

    # Self is never a peer: Kari's own C3 (where her cursor sits) carries
    # no peer tag in HER view — only the in-bar avatar shows herself.
    refute peer_cursor(kari, "C3") =~ "sheet-peer-tag"

    # ── 2. Ola selects B2:D5 — Kari sees the overlay in Ola's color ────────
    render_hook(ola_grid, "presence-meta", %{"active" => "B2", "selection" => "B2:D5"})

    eventually(fn ->
      sel = peer_selection(kari, "B2:D5")
      assert sel =~ "sheet-peer-sel"
      assert sel =~ overlay_rgba(ola_color)
      # ONE rect covering exactly B2..D5 (default 88x24 cells, x 44+88,
      # y 25+24, three columns by four rows) — E6 stays clean because the
      # rect ends at D5's edges.
      assert sel =~ "left: 132px; top: 49px; width: 264px; height: 96px"
    end)

    # ── 3. Kari edits C3 — soft lock up, 4200 commits, lock clears ─────────
    render_hook(kari_grid, "edit-start", %{})

    eventually(fn ->
      c3 = peer_cursor(ola, "C3")
      assert c3 =~ "sheet-peer-editing"
      assert c3 =~ "Kari"
    end)

    render_hook(kari_grid, "edit-commit", %{"value" => "4200", "move" => "none"})

    eventually(fn ->
      assert cell(ola, "C3") =~ ~s(data-v="4200")
      refute render(ola) =~ "sheet-peer-editing"
    end)

    # PUBLISH-GATE: the public dashboard shows the PUBLISHED value, never
    # the live draft (the editors above already synchronized on the delta,
    # so the frame had every chance to arrive — it must not apply here).
    refute cell(reader, "C3") =~ ~s(data-v="4200")
    assert cell(reader, "C3") =~ ~s(data-v="2100")

    # ── 4. Ola enters =C3*2 into D3 through the formula bar ────────────────
    render_hook(ola_grid, "cell-click", %{"ref" => "D3", "shift" => false})
    render_submit(ola_grid, "bar-commit", %{"value" => "=C3*2"})

    eventually(fn -> assert cell(kari, "D3") =~ ~s(data-v="8400") end)
    # The dashboard still shows only published content — no D3 draft value,
    # and C3 is STILL the published figure (a late-arriving draft delta
    # from step 3 would be caught here).
    refute cell(reader, "D3") =~ ~s(data-v="8400")
    assert cell(reader, "C3") =~ ~s(data-v="2100")

    # ── 5. Kari's Cmd+Z — her 4200 reverts EVERYWHERE, D3 recomputes ───────
    render_hook(kari_grid, "undo", %{})

    for view <- [kari, ola] do
      eventually(fn ->
        assert cell(view, "C3") =~ ~s(data-v="2100")
        assert cell(view, "D3") =~ ~s(data-v="4200")
      end)
    end

    # …and Cmd+Shift+Z brings it back.
    render_hook(kari_grid, "redo", %{})

    for view <- [kari, ola] do
      eventually(fn ->
        assert cell(view, "C3") =~ ~s(data-v="4200")
        assert cell(view, "D3") =~ ~s(data-v="8400")
      end)
    end

    # ── 6. the dashboard is pure glass: zero edit affordances, no presence ─
    reader_now = render(reader)
    assert cell(reader, "C3") =~ ~s(data-v="2100")
    refute reader_now =~ ~s(phx-hook="SheetGrid")
    refute reader_now =~ ~s(data-test-id="sheet-formula-bar")
    refute reader_now =~ ~s(data-test-id="sheet-namebox")
    refute reader_now =~ ~s(data-test-id="sheet-cell-input")
    refute reader_now =~ "sheet-toolbar"
    refute reader_now =~ "edit-commit"
    refute reader_now =~ "bar-commit"
    refute reader_now =~ "rowcol-insert"
    refute reader_now =~ "sheet-rsz"
    refute reader_now =~ "menu-open"
    refute reader_now =~ ~s(data-test-id="sheet-tab-add")
    refute reader_now =~ "sheet-peer-tag"

    # ── 7. Ola disconnects — his cursor vanishes, no ghosts ────────────────
    eventually(fn -> assert peer_layer(kari) =~ "Ola" end)

    Process.flag(:trap_exit, true)
    GenServer.stop(ola.pid)

    eventually(fn ->
      html = render(kari)
      refute peer_layer(kari) =~ "Ola"
      refute html =~ "sheet-peer-tag"
      refute html =~ "sheet-peer-sel"
    end)

    # The sheet itself is untouched by his departure — and the public
    # dashboard still shows only the published content (publish-gate).
    assert cell(kari, "C3") =~ ~s(data-v="4200")
    assert cell(reader, "C3") =~ ~s(data-v="2100")
    refute cell(reader, "D3") =~ ~s(data-v="8400")
  end
end
