defmodule BarkparkWeb.Studio.PdsW42PaperCanvasPathGateTest do
  @moduledoc """
  pds-w42-bl-paper-canvas-path-unmeasured — the CANVAS paper path's own write
  door, measured end-to-end for a write-denied principal.

  WHY A SECOND FILE. `PdsW42PaperOpPrincipalGateTest` proves the chokepoint
  (`Shared.Paper.paper_pane_op/2` / `paper_ops/2`) refuses a write-denied
  principal, and it does exercise the canvas default for the COMPONENT route
  (`inner-change` at a composite `PaperFieldBlock`, a canvas run BOUNDARY). What
  it does not drive is the canvas's OWN front door: the batch that a
  `<bp-paper-canvas>` run emits as a `bp-canvas-ops` CustomEvent, which the
  `BarkparkPaperCanvas` JS hook forwards verbatim as `pushEvent("paper-ops",
  {ops: […]})`. Its batch test reaches `Shared.paper_ops/2` by DIRECT CALL,
  deliberately "bypassing the socket gate the `paper-ops` event would hit" — so
  the event route itself, the one every real canvas keystroke takes, was never
  run against a denied principal.

  This file drives that route: `render_hook(view, "paper-ops", %{"ops" => …})`
  on a paper whose blocks are all canvas-eligible prose (ONE maximal run, so
  the surface under test is a real `<bp-paper-canvas>`, not a boundary widget).

  VERDICT: GATED, at TWO independent points, and the probe names which one
  actually answers.

    1. `BarkparkWeb.Studio.Caps.gate/3` — the `:studio_caps_gate`
       `attach_hook(_, :handle_event, _)` armed by `Caps.attach/1`. `paper-ops`
       classifies `:write` (it is in `@write_events`), `write_capable?/2` is
       false for this principal, so the hook HALTS and
       `StudioLive.handle_event("paper-ops", …)` never runs. Unlike the
       `handle_info` door PDS-D622 found, this front door IS a `handle_event`,
       so the socket gate is not structurally blind to it.
    2. `Shared.Paper.write_denied?/1`, the pds-w42 chokepoint arm inside
       `paper_ops/2` — the backstop for any caller that reaches the batch seam
       without an event (a `handle_info`, an internal call).

  The two are distinguished by their refusal SHAPE, not by prose:
  `Caps.deny/1` sets the flash only, while `Paper.refuse_write_denied/1` also
  assigns `save_status: "Read-only"`. `save_status` is written ONLY by write
  handlers and otherwise rides at its calm resting value (`Shared` defaults it
  to `""`), so a halted front-door push leaves it exactly where it was — that
  is the run-visible proof the handler never executed.

  NON-VACUITY. The first test is a POSITIVE CONTROL: the identical op array on
  a principal-LESS socket (the intentionally-open public-demo posture, where
  `write_capable?/2` is TRUE by design) DOES land in the store. So every "the
  write did not land" assertion below is falsifiable — it is not passing
  because the op was malformed or the canvas never mounted.

  `async: false` — `BARKPARK_PAPER_CANVAS` is a process-global env var.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.Shared

  @dataset "production"
  @readonly "pds-w42c-readonly"
  @block_id "p-intro"
  @orig [%{"type" => "text", "value" => "Original intro."}]
  @attempt [%{"type" => "text", "value" => "CANVAS ESCALATION"}]
  @deny_flash "You don't have access to do that."

  setup do
    prev = System.get_env("BARKPARK_PAPER_CANVAS")

    # THE DEFAULT, pinned rather than inherited: unset means canvas-ON (the
    # D7/D9 cutover). The wave-42 run proof pinned "0" (the legacy per-block
    # editor); this file is the other setting.
    System.delete_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    seed_paper_schema!()

    # A READ-ONLY api token. `create_token` auto-memberships it on the Default
    # workspace, so it IS a member — permissions are ["read"], so the write arm
    # of `Caps.derive/1` is false. Authenticated, not anonymous.
    {:ok, _} = Auth.create_token(@readonly, "pds w42 canvas readonly", @dataset, ["read"])

    :ok
  end

  defp seed_paper_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "📰",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  # A paper whose blocks are ALL canvas-eligible prose (heading + paragraph), so
  # the flag-ON pane renders them as ONE maximal run inside a single
  # <bp-paper-canvas>. This is the surface the canvas front door belongs to —
  # deliberately NOT a composite field block, which is a run boundary and would
  # route through the component/`handle_info` door the wave-42 file already owns.
  defp create_paper!(slug) do
    blocks = [
      %{"id" => "h-1", "type" => "heading", "level" => 1, "text" => "W42 Canvas"},
      %{"id" => @block_id, "type" => "paragraph", "content" => @orig}
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: @dataset, blocks: blocks})
      )

    paper
  end

  # The paragraph's content as PERSISTED STATE reports it — re-read from the
  # store (the same read `sync_paper_edit_doc/1` uses), never from an assign, so
  # the assertion is falsifiable in both directions.
  defp stored_content(slug) do
    Content.paper_blocks(slug, @dataset)
    |> Enum.find(%{}, &(Map.get(&1, "id") == @block_id))
    |> Map.get("content")
  end

  # The op array a canvas run's `bp-canvas-ops` detail carries, verbatim in the
  # shape the JS hook forwards.
  defp patch_ops do
    [%{"op" => "patch-block", "id" => @block_id, "patch" => %{"content" => @attempt}}]
  end

  defp open!(conn, token, slug) do
    {:ok, view, _html} =
      conn
      |> Plug.Test.init_test_session(%{"api_token" => token})
      |> live(scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))

    view
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
  defp paper_rev(view), do: socket_of(view).assigns.paper_rev

  defp paper_ops_params(view) do
    %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => paper_rev(view),
      "ops" => patch_ops()
    }
  end

  # The canvas really is the rendered editor for this paper — asserted before
  # every denial, so "the write did not land" can never mean "there was no
  # canvas to write from".
  defp assert_canvas_mounted!(view) do
    html = render(view)
    assert html =~ ~s(data-test-id="paper-canvas-run")
    assert html =~ "<bp-paper-canvas>"
    :ok
  end

  # The write-denial asserted ON THE LIVE SOCKET — not assumed from the fixture.
  defp assert_write_denied_socket!(view) do
    socket = socket_of(view)
    caps = Caps.derive(socket)
    assert caps.write == false
    assert Caps.write_capable?(socket.assigns, caps) == false
    :ok
  end

  # ── 0. POSITIVE CONTROL — the op array and the front door both work ─────────

  test "the identical canvas batch LANDS for a write-capable (principal-less) socket",
       %{conn: conn} do
    slug = "pds-w42c-control"
    create_paper!(slug)

    # No api_token, no current_user: `write_capable?/2` is TRUE by design here
    # (the public-demo posture the wave-42 gate deliberately leaves open).
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))

    assert_canvas_mounted!(view)
    socket = socket_of(view)
    assert Caps.write_capable?(socket.assigns, Caps.derive(socket)) == true

    render_hook(view, "paper-ops", paper_ops_params(view))

    # Read back from the STORE. This is what a denied principal would have got
    # if either gate were missing.
    assert stored_content(slug) == @attempt
    assert socket_of(view).assigns[:save_status] == "Auto-saved"
  end

  # ── 1. THE PROBE — the canvas front door, write-denied principal ────────────

  describe "the CANVAS front door (paper-ops) for a write-denied principal" do
    test "the batch is refused and the persisted paper is untouched", %{conn: conn} do
      slug = "pds-w42c-probe"
      create_paper!(slug)

      view = open!(conn, @readonly, slug)
      assert_write_denied_socket!(view)
      assert_canvas_mounted!(view)

      render_hook(view, "paper-ops", paper_ops_params(view))

      render(view)

      # THE CENTRAL CLAIM, read from the store.
      assert stored_content(slug) == @orig
      assert socket_of(view).assigns.flash["error"] == @deny_flash
    end

    test "the refusing mechanism is Caps.gate/3 — the handler never runs", %{conn: conn} do
      slug = "pds-w42c-mechanism"
      create_paper!(slug)

      view = open!(conn, @readonly, slug)
      assert_write_denied_socket!(view)
      assert_canvas_mounted!(view)

      # `paper-ops` is in Caps' @write_events, so it is enforced at the :write
      # tier — this suite does not lean on the default-DENY fallback.
      assert Caps.classify("paper-ops") == :write

      # Nothing has written yet, so save_status rides at its calm resting
      # value — captured, not assumed, so the comparison below is a CHANGE
      # test rather than a hardcoded token.
      before = socket_of(view).assigns[:save_status]
      assert before != "Read-only"

      render_hook(view, "paper-ops", paper_ops_params(view))

      render(view)

      after_socket = socket_of(view)

      # THE DISCRIMINATOR. `Caps.deny/1` sets the flash and nothing else;
      # `Paper.refuse_write_denied/1` would ALSO have assigned "Read-only". The
      # flash is set and save_status did not move ⇒ the socket hook halted the
      # event and `handle_event("paper-ops", …)` never executed. The next test
      # shows the chokepoint's own refusal DOES move it, so this is a real
      # discriminator and not an artefact of nothing happening.
      assert after_socket.assigns.flash["error"] == @deny_flash
      assert after_socket.assigns[:save_status] == before
      assert after_socket.assigns[:save_status] != "Read-only"
      assert stored_content(slug) == @orig
    end

    test "the chokepoint independently refuses the same batch, hook or no hook",
         %{conn: conn} do
      slug = "pds-w42c-chokepoint"
      create_paper!(slug)

      view = open!(conn, @readonly, slug)
      assert_write_denied_socket!(view)
      assert_canvas_mounted!(view)

      # Straight at `Shared.paper_ops/2` with the SAME batch, as a `handle_info`
      # or an internal caller would arrive — no `:handle_event` hook on the
      # path. This is the second, independent gate: `write_denied?/1`.
      socket = socket_of(view)

      assert {:error, out} =
               Shared.paper_ops(
                 socket,
                 patch_ops(),
                 Ecto.UUID.generate(),
                 socket.assigns.paper_rev
               )

      # Its refusal shape, distinct from the socket gate's.
      assert out.assigns.save_status == "Read-only"
      assert out.assigns.flash["error"] == @deny_flash
      assert stored_content(slug) == @orig
    end
  end

  # ── 2. denied WRITE is not denied READ ──────────────────────────────────────

  test "the canvas paper still opens and renders for the denied principal", %{conn: conn} do
    slug = "pds-w42c-read"
    create_paper!(slug)

    view = open!(conn, @readonly, slug)
    html = render(view)

    assert html =~ "W42 Canvas"
    assert html =~ ~s(data-test-id="paper-canvas-run")
  end
end
