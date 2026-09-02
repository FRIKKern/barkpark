defmodule BarkparkWeb.Studio.PdsW42HandleInfoWriteSeamTest do
  @moduledoc """
  pds-w42-bl-handle-info-write-seam-audit — the THIRD hook-invisible door.

  THE CLASS. `Caps.attach/1` arms the Studio deny-gate as
  `attach_hook(_, :handle_event, _)`. That hook is structurally blind to a
  write that happens in `handle_INFO`: no `:handle_event` hook, parent or
  component, ever observes a message. Two doors in this family were closed
  before this slice — the cid-targeted component event (pds-w41) and
  `{:paper_op, …}` (pds-w42-paper-op-principal-gate). This suite sweeps the
  REMAINING `handle_info` heads on `StudioLive` and `ChatLive` and pins the
  answer for each.

  WHAT THE SWEEP FOUND. `{:autosave_form, form}` →
  `Lifecycle.autosave_form/2` → `Shared.do_autosave/2` → `Content.upsert_draft`
  reached persisted state with NO principal check of its own. Its only guard
  was the socket gate on the FIVE parent events that send to it today
  (select-media / clear-image / upload-image / select-ref / clear-ref, all in
  `Caps` `@write_events`) — an argument about today's callers, not a property
  of the seam, and exactly the argument that was true of `paper_op` right up
  until `PaperFieldBlock` started sending to it. The remedy is the same as the
  paper one: gate the CHOKEPOINT, through `Caps.write_capable?/2` — the single
  copy — reusing `Shared.Paper.write_denied?/1` rather than forking a second
  predicate.

  HONEST SCOPE, unchanged from the paper slice: "any principal `Caps` denies
  write" — a read-only api_token or a read-only member. NOT "anonymous":
  `write_capable?/2` returns TRUE for a principal-LESS socket by design (the
  public-demo posture), and one test here pins that it still does.

  `async: false` — these mounts share the seeded Default workspace.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}
  alias Barkpark.Content.DraftId
  alias BarkparkWeb.Studio.Caps

  @dataset "production"
  @readonly "pds-w42-hi-readonly"
  @writer "pds-w42-hi-writer"
  @doc_id "hi-seam-post"

  # ── the census, pinned ──────────────────────────────────────────────────────
  #
  # A prose census rots the moment someone adds a fifteenth head; these lists
  # fail. Each entry is `{head-source-fragment, :write | :no_write}`. A head
  # classified `:write` is covered by a run below or by the sibling suite named
  # in its comment.

  # StudioLive — 14 heads today. `:write` = reaches persisted state.
  @studio_heads [
    # grant reload + flash; `load_access_grants`/`refresh_caps` are reads
    {"{:airdrop_granted}", :no_write},
    # `refresh_grant_access` + `enforce_admission`: reads, then maybe kill
    {":access_expiry_tick", :no_write},
    {"{:airdrop_revoked}", :no_write},
    # Lifecycle.doc_updated/2 — assigns only (form refresh or conflict banner)
    {"{:doc_updated, msg}", :no_write},
    # Lifecycle.paper_block/2 — refetch/apply delta into assigns + client push
    {"{:paper_block, frame}", :no_write},
    # Lifecycle.paper_updated/2 — assigns only
    {"{:paper_updated, msg}", :no_write},
    # Lifecycle.sheets_op/2 — send_update to SheetGrid, whose `%{sheets_op:}`
    # update/2 clause is `apply_delta` + `derive_grid`: in-memory, no persist
    {"{:sheets_op, payload}", :no_write},
    # Lifecycle.sheets_persisted/2 — send_update, save-state indicator only
    {"{:sheets_persisted, payload}", :no_write},
    {"presence_diff", :no_write},
    # Lifecycle.document_changed/2 — `rebuild_panes` is a read
    {"{:document_changed, msg}", :no_write},
    # THE SEAM THIS SLICE CLOSES — Content.upsert_draft
    {"{:autosave_form, form}", :write},
    # closed by pds-w42-paper-op-principal-gate (its own suite)
    {"{:paper_op, ", :write},
    # send_update(PaperFieldBlock, tree_value:) → persist/2 → {:paper_op, …};
    # terminates on the paper chokepoint (covered by the paper-op suite)
    {"{:tree_codelist_change, msg}", :write},
    {"(_other, socket)", :no_write}
  ]

  # ChatLive — 44 heads today. Only the store-touching ones are listed; all of
  # them write on `socket.assigns.store_session_id`, which is established at
  # mount/handle_params and NEVER taken from the message payload, so none can
  # name another tenant's row the way the by-id `handle_event` clauses could
  # (that is `tenancy_permits?/2`'s job, PR #14593).
  #
  # `{:claude_chat_task_hands, verdict}` (task-token renewal) is classified
  # `:no_write`: its whole body is
  # `assign(socket, readiness: readiness_for_hands(verdict))` — a pure atom→atom
  # map into assigns, no Content/StudioChat call on the path. It is driven by a
  # run in chat_live_test.exs ("a renewal that lands mid-session flips the card
  # in place"), which sends both `:rearmed` and `:expired` to a live socket.
  #
  # 44 -> 43: `:turn_tick` left when the turn clock moved into the browser
  # (Hooks.ChatElapsed). It was a `:no_write` head — assigns only — so nothing
  # in this list changes with it.
  #
  # 43 -> 44: `{:chat_reported_state, sid, _frame}` arrived (chat-local-cloud-
  # context-w3 — a registered host's authoritative state report, reused to
  # refresh the transcript's context band), classified `:no_write`: its whole
  # body is a `store_session_id` equality guard around
  # `assign_context_identity/1`, whose reads are `StudioChat.get_session/2`,
  # `ChatHosts.session_execution_identity/1` and `Tenancy.get_workspace_by_id/1`
  # — three SELECTs and no store write. (The report's own persisted write is
  # `ChatHosts.report_state/4`'s, server-side, long before this frame is
  # broadcast.) It is driven by runs in chat_context_band_test.exs.
  @chat_write_heads [
    # ensure_session → StudioChat.create_session; persist_user_message →
    # persist_store → StudioChat.append_message
    "{:dispatch_send, text, queued?}",
    # persist_mode → StudioChat.set_mode(store_session_id, mode)
    "{:claude_chat_control, :set_mode, request_id, response}"
  ]

  setup do
    seed_schema!()

    # READ-ONLY api token. `create_token` auto-memberships it on the Default
    # workspace, so it IS a member and CAN read — its permission array is
    # ["read"], so the write arm of `Caps.derive/1` is false.
    {:ok, _} = Auth.create_token(@readonly, "pds w42 hi readonly", @dataset, ["read"])
    {:ok, _} = Auth.create_token(@writer, "pds w42 hi writer", @dataset, ["read", "write"])

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => @doc_id, "title" => "Seam Post", "content" => %{"body" => "ORIGINAL"}},
        @dataset
      )

    :ok
  end

  defp seed_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "text"}
          ]
        },
        @dataset
      )
  end

  # THE STORE ORACLE. `Shared.do_autosave/2` → `Content.upsert_draft/6` writes
  # the DRAFT row (`DraftId.draft_id/1`), never the published one, so the draft
  # is where an escaped write shows up. Reading the published row instead would
  # be the vacuous oracle: it stays "ORIGINAL" whether the gate holds or not.
  #
  # `Content.create_document/3` seeds the row as a DRAFT, so the untouched
  # baseline is `{"ORIGINAL", :absent}` — the draft carries the bytes and there
  # is no published row yet. Returned as a PAIR so a test can never
  # accidentally assert on the half that cannot move (reading the published
  # half alone would pass whether the gate holds or not).
  defp stored_body do
    {draft_body(), published_body()}
  end

  defp draft_body do
    case Content.get_document(DraftId.draft_id(@doc_id), "post", @dataset) do
      {:ok, doc} -> get_in(doc.content, ["body"])
      _ -> :no_draft
    end
  end

  defp published_body do
    case Content.get_document(@doc_id, "post", @dataset) do
      {:ok, doc} -> get_in(doc.content, ["body"])
      _ -> :absent
    end
  end

  # The state the store is in before any write reaches it.
  @untouched {"ORIGINAL", :absent}

  defp open!(conn, token) do
    {:ok, view, _html} =
      conn
      |> Plug.Test.init_test_session(%{"api_token" => token})
      |> live(scoped_studio("/d/#{@dataset}/studio/post/#{@doc_id}"))

    view
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket

  # The write-denial asserted ON THE LIVE SOCKET — not assumed from the
  # fixture. `derive/1` re-reads membership + grants exactly as the gate does.
  defp assert_write_denied_socket!(view) do
    socket = socket_of(view)
    caps = Caps.derive(socket)
    assert caps.write == false
    assert Caps.write_capable?(socket.assigns, caps) == false
    :ok
  end

  # Drive the seam the way a future in-process sender would, then force the
  # LiveView to drain its mailbox before the store is read. Reading straight
  # after `send/2` reads BEFORE the message is processed and reports a false
  # "no write" — the vacuity trap this whole class invites.
  defp drive_seam(view, message) do
    send(view.pid, message)
    render(view)
    :ok
  end

  # ── 1. the census, as a test that keeps answering ───────────────────────────

  describe "census" do
    test "every StudioLive handle_info head is enumerated and classified" do
      heads = handle_info_heads("lib/barkpark_web/live/studio/studio_live.ex")

      assert length(heads) == 14,
             "studio_live.ex handle_info head count moved to #{length(heads)}; " <>
               "classify the new head in @studio_heads and give a :write one a run."

      for {fragment, _class} <- @studio_heads do
        assert Enum.any?(heads, &String.contains?(&1, fragment)),
               "classified head #{inspect(fragment)} is no longer in studio_live.ex"
      end

      # Every head in the source is accounted for by the pinned list — a new
      # head lands here, unclassified, and reds.
      unclassified =
        Enum.reject(heads, fn head ->
          Enum.any?(@studio_heads, fn {fragment, _} -> String.contains?(head, fragment) end)
        end)

      assert unclassified == [],
             "unclassified handle_info head(s) in studio_live.ex: #{inspect(unclassified)}"
    end

    test "every ChatLive handle_info head is enumerated, and the store-touching ones are pinned" do
      heads = handle_info_heads("lib/barkpark_web/live/studio/chat_live.ex")

      assert length(heads) == 44,
             "chat_live.ex handle_info head count moved to #{length(heads)}; " <>
               "re-run the write classification over the new head."

      for fragment <- @chat_write_heads do
        assert Enum.any?(heads, &String.contains?(&1, fragment)),
               "pinned write-bearing ChatLive head #{inspect(fragment)} is gone"
      end
    end

    # The row cited nine `send(self(), {…})` sites. The measured set is EIGHT
    # in the LiveView/component tree (the two remaining tree-wide sends are
    # `:after_join` in the channels, which are not LiveView seams). Pinning the
    # set means a NEW in-process sender — the exact event that turned
    # `paper_op` from "safe by construction" into a live bypass — cannot land
    # unnoticed.
    test "the set of in-process send(self(), …) senders is pinned" do
      assert send_self_sites() == [
               {"components/fields/tree_codelist_field.ex", "{:tree_codelist_change,"},
               {"live/studio/chat_live.ex", "{:dispatch_send,"},
               {"live/studio/paper_field_block.ex", "{:paper_op,"},
               {"live/studio/studio_live/handlers/media.ex", "{:autosave_form,"},
               {"live/studio/studio_live/handlers/media.ex", "{:autosave_form,"},
               {"live/studio/studio_live/handlers/media.ex", "{:autosave_form,"},
               {"live/studio/studio_live/handlers/refs.ex", "{:autosave_form,"},
               {"live/studio/studio_live/handlers/refs.ex", "{:autosave_form,"}
             ]
    end
  end

  # ── 2. the autosave seam: the run, not a reading ────────────────────────────

  describe "a write-denied principal at the {:autosave_form, …} seam" do
    test "ROUTE A (control): the `autosave` handle_event is halted by the socket gate",
         %{conn: conn} do
      view = open!(conn, @readonly)
      assert_write_denied_socket!(view)

      # `autosave` is a :write event, NOT the default-DENY tier — this suite
      # proves the write tier, not unclassified-event fallout.
      assert Caps.classify("autosave") == :write

      render_hook(view, "autosave", %{
        "doc" => %{"title" => "Seam Post", "body" => "ESCALATED-VIA-EVENT"}
      })

      # STORE FIRST.
      assert stored_body() == @untouched
      assert socket_of(view).assigns.flash["error"] == "You don't have access to do that."
    end

    test "ROUTE B (the seam): the same intent as a MESSAGE is refused too", %{conn: conn} do
      view = open!(conn, @readonly)
      assert_write_denied_socket!(view)

      # No `:handle_event` hook is on this path at all — this is what a future
      # LiveComponent sender, or a fifteenth handler, would produce.
      drive_seam(
        view,
        {:autosave_form, %{"title" => "Seam Post", "body" => "ESCALATED-VIA-INFO"}}
      )

      # NON-VACUOUS: read back from the STORE. Remove the chokepoint gate and
      # this prints `left: "ESCALATED-VIA-INFO"`.
      assert stored_body() == @untouched
    end

    test "the seam reports the refusal honestly instead of claiming a save", %{conn: conn} do
      view = open!(conn, @readonly)

      drive_seam(view, {:autosave_form, %{"title" => "Seam Post", "body" => "ESCALATED-STATUS"}})

      # STORE FIRST — the mechanism assertions below must never shadow it.
      assert stored_body() == @untouched

      socket = socket_of(view)
      assert socket.assigns.save_status == "Read-only"
      assert socket.assigns.flash["error"] == "You don't have access to do that."
    end

    # POSITIVE CONTROL. Refute-on-absence alone cannot tell "the gate works"
    # from "my fixture never drove anything". The SAME seam, the SAME message,
    # a principal who IS entitled — the bytes must land.
    test "POSITIVE CONTROL: a write-capable member drives the same seam and the write LANDS",
         %{conn: conn} do
      view = open!(conn, @writer)

      socket = socket_of(view)
      assert Caps.write_capable?(socket.assigns, Caps.derive(socket)) == true

      drive_seam(view, {:autosave_form, %{"title" => "Seam Post", "body" => "ENTITLED-WRITE"}})

      assert stored_body() == {"ENTITLED-WRITE", :absent}
    end

    # The public-demo posture survives. `write_capable?/2` returns TRUE for a
    # principal-LESS socket BY DESIGN; nobody may read this gate as "anonymous
    # is now denied".
    test "a principal-LESS socket is NOT denied — the write still lands", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/post/#{@doc_id}"))

      socket = socket_of(view)
      assert Caps.write_capable?(socket.assigns, Caps.derive(socket)) == true

      drive_seam(view, {:autosave_form, %{"title" => "Seam Post", "body" => "ANON-WRITE"}})

      assert stored_body() == {"ANON-WRITE", :absent}
    end

    # Denied WRITE is not denied READ.
    test "the document still opens and renders for the denied principal", %{conn: conn} do
      view = open!(conn, @readonly)
      html = render(view)

      assert html =~ ~s(id="editor-form")
      assert html =~ "Seam Post"
    end
  end

  # ── 3. every OTHER StudioLive head, driven on a write-denied socket ─────────

  describe "the non-write-bearing StudioLive heads, proven by run" do
    # The classification `:no_write` is asserted, not read: each message is
    # DELIVERED to a live write-denied socket and the store oracle must be
    # untouched afterwards. A head that quietly grows a write reds here.
    test "delivering each :no_write head leaves the store untouched", %{conn: conn} do
      view = open!(conn, @readonly)
      assert_write_denied_socket!(view)

      # `self()` here is the TEST process, so every payload below arrives as a
      # FOREIGN sender — the `sender == self()` self-write short-circuits in
      # `doc_updated/2`, `paper_block/2` and `document_changed/2` are NOT the
      # branch taken, so those bodies really run. The paper/sheet heads reach
      # their `editor_view` guard instead, which is the honest behaviour for a
      # socket sitting on a FORM editor.
      {:ok, doc} = Content.get_document(DraftId.draft_id(@doc_id), "post", @dataset)

      messages = [
        {:airdrop_granted},
        :access_expiry_tick,
        {:airdrop_revoked},
        {:doc_updated, %{sender: self(), doc: doc}},
        {:paper_block, %{sender: self(), rev: 1, block_id: "b-1"}},
        {:paper_updated, %{sender: self(), html: "<p>x</p>", rev: 2}},
        {:sheets_op, %{rev: 1}},
        {:sheets_persisted, %{ok: true, epoch: 1, rev: 1, saved_at: nil}},
        %Phoenix.Socket.Broadcast{event: "presence_diff", topic: "nope", payload: %{}},
        {:document_changed, %{type: "post", sender: self()}},
        {:some_message_nobody_handles, "x"}
      ]

      for msg <- messages do
        send(view.pid, msg)
      end

      render(view)

      assert stored_body() == @untouched
    end
  end

  # ── 4. ChatLive's {:dispatch_send} seam — unreachable, by run ───────────────

  describe "ChatLive's write-bearing handle_info seams" do
    # `{:dispatch_send, …}` writes (create_session + append_message). The proof
    # the row asks for is "a write-denied principal cannot REACH it": both chat
    # routes sit inside an admin-gated `live_session`, so a read-only token
    # never gets a socket to send to. Proven by mount, not by reading the
    # router.
    test "a write-denied principal cannot mount ChatLive at all", %{conn: conn} do
      result =
        conn
        |> Plug.Test.init_test_session(%{"api_token" => @readonly})
        |> live("/studio/chat")

      assert {:error, _} = result
    end
  end

  # ── source helpers ──────────────────────────────────────────────────────────

  defp api_root do
    Path.expand("../../../..", __DIR__)
  end

  defp handle_info_heads(rel) do
    api_root()
    |> Path.join(rel)
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&Regex.match?(~r/^\s*def handle_info/, &1))
    |> Enum.map(&String.trim/1)
  end

  defp send_self_sites do
    root = Path.join(api_root(), "lib/barkpark_web")

    root
    |> find_ex_files()
    |> Enum.flat_map(fn path ->
      rel = Path.relative_to(path, root)

      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/send\(self\(\), (\{[a-z_:]+,)/, line) do
          [_, tag] -> [{rel, tag}]
          nil -> []
        end
      end)
    end)
    |> Enum.sort()
  end

  defp find_ex_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      cond do
        File.dir?(path) -> find_ex_files(path)
        String.ends_with?(entry, ".ex") -> [path]
        true -> []
      end
    end)
  end
end
