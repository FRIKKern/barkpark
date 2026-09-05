defmodule BarkparkWeb.Studio.PdsW42PaperOpPrincipalGateTest do
  @moduledoc """
  pds-w42-paper-op-principal-gate — the paper editor's SECOND route to
  persisted state, and why a component PROP could not have closed it.

  MECHANISM (source, not prose). `paper_editor.ex` instantiates
  `PaperFieldBlock` with `id` + `block` only — no capability prop of any kind
  (unlike `SheetGrid`, which wave 41 fixed that way). But the prop shape is not
  even the applicable remedy here: the component does not write. `persist/2`
  does `send(self(), {:paper_op, op})` (paper_field_block.ex), which lands in
  `studio_live.ex`'s `handle_info({:paper_op, …})` → `Shared.paper_op/2` →
  `paper_pane_op/2` → `Content.apply_paper_block_op/4`. `attach_hook(_,
  :handle_event, _)` cannot see a `handle_info` on ANY socket, so the Studio
  `Caps` deny-gate is structurally blind to this path even on the PARENT
  socket — the cid only decides which socket runs the component event; the
  write happens later, on the parent, as a message.

  So the gate has to be at the CHOKEPOINT (`Shared.Paper.paper_pane_op/2` and
  its batch sibling `paper_ops/2`), whose only guards before this fix were
  `read_only_pane?/1` (a doc-TYPE check: session vs paper) and `is_nil(slug)`.

  HONEST SCOPE: "any principal `Caps` denies write" — a read-only api_token or
  a read-only member. NOT "anonymous", NOT "the internet":
  `Caps.write_capable?/2` returns TRUE for a principal-LESS socket by design
  (the public-demo posture), and the last test here pins that it still does.

  `paper-op` classifies `:write`, NOT `:deny` — this suite does not lean on the
  default-DENY tier.

  `async: false` — the canvas flag is a process-global env var.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}
  alias BarkparkWeb.Studio.Caps

  @dataset "production"
  @readonly "pds-w42-readonly"
  @block_id "fb-price"

  setup do
    prev = System.get_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    seed_paper_schema!()

    # A READ-ONLY api token. `create_token` auto-memberships it on the Default
    # workspace, so it IS a member — its permission array is ["read"], so the
    # write arm of `Caps.derive/1` is false. Authenticated, not anonymous.
    {:ok, _} = Auth.create_token(@readonly, "pds w42 readonly", @dataset, ["read"])

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

  # A paper carrying ONE v2 `composite` field block — the block kind that
  # renders as a nested `PaperFieldBlock` LiveComponent. It is a run BOUNDARY
  # on the canvas path too (paper_canvas.ex: composite / arrayOf / codelist /
  # localizedText are excluded from every canvas set), so this component is the
  # editor for it under BOTH canvas settings.
  defp create_paper!(slug) do
    blocks = [
      %{"id" => "h-1", "type" => "heading", "text" => "W42"},
      %{
        "id" => @block_id,
        "type" => "composite",
        "label" => "Price",
        "fields" => [
          %{"name" => "amount", "title" => "Amount", "type" => "string"},
          %{"name" => "currency", "title" => "Currency", "type" => "string"}
        ],
        "value" => %{"amount" => "299", "currency" => "NOK"}
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: @dataset, blocks: blocks})
      )

    paper
  end

  # The composite block's value as PERSISTED STATE would report it — read back
  # from the store, never from an assign, so the assertion is falsifiable in
  # both directions.
  defp stored_value(slug) do
    paper = Content.get_paper(slug, @dataset)

    blocks =
      get_in(paper.content, ["blocks"]) || get_in(paper.content, ["body", "blocks"]) || []

    blocks
    |> Enum.find(%{}, &(Map.get(&1, "id") == @block_id))
    |> Map.get("value")
  end

  defp open!(conn, token, slug) do
    {:ok, view, _html} =
      conn
      |> Plug.Test.init_test_session(%{"api_token" => token})
      |> live(scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))

    view
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket

  defp flash_error(view), do: socket_of(view).assigns.flash["error"]

  # The write-denial asserted ON THE LIVE SOCKET — not assumed from the
  # fixture. `derive/1` re-reads membership + grants exactly as the gate does.
  defp assert_write_denied_socket!(view) do
    socket = socket_of(view)
    caps = Caps.derive(socket)
    assert caps.write == false
    assert Caps.write_capable?(socket.assigns, caps) == false
    :ok
  end

  # The component event, THEN a round-trip on the parent. `persist/2` does
  # `send(self(), {:paper_op, …})`, so the write happens in a LATER
  # `handle_info` — reading the store straight after `render_hook/3` reads it
  # BEFORE the message is processed and reports a false "no write". The
  # trailing `render/1` forces the parent to drain its mailbox first.
  defp inner_change(view, params) do
    view
    |> with_target("#paper-fb-" <> @block_id)
    |> render_hook("inner-change", params)

    render(view)
    :ok
  end

  # ── 1. the bypass: two routes, one socket, one principal ────────────────────

  describe "a write-denied principal at the paper editor's two write routes" do
    test "LEGACY per-block editor: the cid-targeted inner-change is refused, and so is paper-op",
         %{conn: conn} do
      System.put_env("BARKPARK_PAPER_CANVAS", "0")
      slug = "pds-w42-legacy"
      create_paper!(slug)

      view = open!(conn, @readonly, slug)
      assert_write_denied_socket!(view)

      # `paper-op` is a :write event, NOT the default-DENY tier — this suite
      # proves the write tier, not unclassified-event fallout.
      assert Caps.classify("paper-op") == :write

      # Flag-OFF opens in View; the Edit toggle is a :none event, so a denied
      # principal may legitimately reach edit mode. That is the point: reading
      # is not denied.
      render_click(view, "paper-toggle-edit")
      assert render(view) =~ ~s(id="paper-fb-#{@block_id}")

      # ROUTE A — the CONTROL, straight at the LiveView. The socket-level Caps
      # hook sees `paper-op` and halts it.
      render_hook(view, "paper-op", %{
        "op" => "patch-block",
        "id" => @block_id,
        "patch" => %{"value" => %{"amount" => "299", "currency" => "USD"}}
      })

      assert flash_error(view) == "You don't have access to do that."
      assert stored_value(slug) == %{"amount" => "299", "currency" => "NOK"}

      # ROUTE B — the SAME intent, same socket, same principal, entering
      # through the component's cid and leaving through `handle_info`. No
      # `:handle_event` hook is on this path at all.
      inner_change(view, %{"amount" => "299", "currency" => "USD"})

      # NON-VACUOUS: read back from the STORE. Remove the chokepoint gate and
      # this prints `left: %{"amount" => "299", "currency" => "USD"}`.
      after_component_event = stored_value(slug)
      assert after_component_event == %{"amount" => "299", "currency" => "NOK"}
    end

    test "DEFAULT canvas editor: the same cid route is refused there too", %{conn: conn} do
      # Composite blocks are canvas run BOUNDARIES, so PaperFieldBlock is the
      # editor for them with the canvas ON as well — this path is the DEFAULT,
      # not the legacy opt-out.
      System.delete_env("BARKPARK_PAPER_CANVAS")
      slug = "pds-w42-canvas"
      create_paper!(slug)

      view = open!(conn, @readonly, slug)
      assert_write_denied_socket!(view)

      # Canvas-on renders the editor directly — no toggle.
      assert render(view) =~ ~s(id="paper-fb-#{@block_id}")

      inner_change(view, %{"amount" => "299", "currency" => "USD"})

      after_component_event = stored_value(slug)
      assert after_component_event == %{"amount" => "299", "currency" => "NOK"}
    end

    test "a correlated component flush is refused and acknowledges the matching request", %{
      conn: conn
    } do
      System.delete_env("BARKPARK_PAPER_CANVAS")
      slug = "pds-w42-correlated"
      create_paper!(slug)

      view = open!(conn, @readonly, slug)
      assert_write_denied_socket!(view)

      send(view.pid, {
        :paper_op,
        %{
          "op" => "patch-block",
          "id" => @block_id,
          "patch" => %{"value" => %{"amount" => "1", "currency" => "USD"}}
        },
        "studio-denied-field-request"
      })

      assert_push_event(view, "bp:paper-field-save-result", %{
        request_id: "studio-denied-field-request",
        saved: false
      })

      assert flash_error(view) == "You don't have access to do that."
      assert stored_value(slug) == %{"amount" => "299", "currency" => "NOK"}
    end

    test "the batch (canvas ops) write seam is refused for the same principal", %{conn: conn} do
      System.delete_env("BARKPARK_PAPER_CANVAS")
      slug = "pds-w42-batch"
      create_paper!(slug)

      view = open!(conn, @readonly, slug)
      assert_write_denied_socket!(view)

      # Straight at `Shared.paper_ops/2` — the batch chokepoint — bypassing the
      # socket gate the `paper-ops` event would hit, exactly as a `handle_info`
      # or an internal caller would.
      socket = socket_of(view)

      BarkparkWeb.Studio.StudioLive.Shared.paper_ops(socket, [
        %{
          "op" => "patch-block",
          "id" => @block_id,
          "patch" => %{"value" => %{"amount" => "1", "currency" => "USD"}}
        }
      ])

      assert stored_value(slug) == %{"amount" => "299", "currency" => "NOK"}
    end

    test "the tree_codelist chain — THREE hook-invisible hops — lands on the same gate", %{
      conn: conn
    } do
      # `tree_codelist_field.ex`'s `tree_node_select` readonly guard is armed
      # only by the CodelistField callsite, which passes NO `notify_id` and so
      # structurally cannot write; the WRITING callsite (PaperFieldBlock) never
      # passes `readonly` at all. The write travels:
      #   tree_node_select (component socket)
      #     → send {:tree_codelist_change, …} → StudioLive handle_info
      #     → send_update(PaperFieldBlock, tree_value: code) → update/2
      #     → persist/2 → send {:paper_op, …} → StudioLive handle_info
      #     → paper_pane_op/2  ← the chokepoint.
      # Driving hop 2 directly proves the chokepoint covers the whole chain
      # without needing a codelist registry to render a tree.
      System.put_env("BARKPARK_PAPER_CANVAS", "0")
      slug = "pds-w42-tree"
      create_paper!(slug)

      view = open!(conn, @readonly, slug)
      assert_write_denied_socket!(view)
      render_click(view, "paper-toggle-edit")

      send(view.pid, {:tree_codelist_change, %{id: "paper-fb-" <> @block_id, value: "USD"}})
      render(view)

      # `update/2`'s `%{tree_value: code}` head persists the picked code as the
      # block's whole value — so an ungated chain would leave "USD" here.
      assert stored_value(slug) == %{"amount" => "299", "currency" => "NOK"}
    end
  end

  # ── 2. denied WRITE is not denied READ ──────────────────────────────────────

  test "the paper still opens and renders for the denied principal", %{conn: conn} do
    System.put_env("BARKPARK_PAPER_CANVAS", "0")
    slug = "pds-w42-read"
    create_paper!(slug)

    view = open!(conn, @readonly, slug)
    html = render(view)

    assert html =~ "W42"
    assert html =~ ~s(data-test-id="studio-paper-editor")
  end

  # ── 3. the public-demo posture survives ─────────────────────────────────────

  test "a principal-LESS socket is NOT denied — the write still lands", %{conn: conn} do
    System.put_env("BARKPARK_PAPER_CANVAS", "0")
    slug = "pds-w42-anon"
    create_paper!(slug)

    # No api_token in the session and no current_user: `write_capable?/2` is
    # TRUE by design here (the intentionally-open public-demo posture). Nobody
    # reading the gate may conclude "anonymous is now denied".
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))

    socket = socket_of(view)
    assert Caps.write_capable?(socket.assigns, Caps.derive(socket)) == true

    render_click(view, "paper-toggle-edit")
    inner_change(view, %{"amount" => "299", "currency" => "USD"})

    assert stored_value(slug) == %{"amount" => "299", "currency" => "USD"}
  end
end
