defmodule BarkparkWeb.Studio.ChatRenderGoldenTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.StudioChat

  # ── The wave-12 NO-TAX byte-lock (charter D66) ──────────────────────────────
  #
  # scc-w12-capabilities introduces `Barkpark.StudioChat.Runtime.Capabilities` and
  # SOURCES `chat_tool_renderer.ex`'s `@spawn_names` out of it. The moat this
  # protects: Claude must render IDENTICALLY pre/post the struct — the matrix is
  # data, not behaviour, so wiring it in taxes nothing on the screen.
  #
  # The proof is a SCOPED-region byte-lock, not a whole-page golden (banned) and
  # not a defp-promotion / clock-freeze (D66 disproved both as prerequisites): the
  # entire clock/randomness surface of chat_live.ex is the SIDEBAR session_stamp
  # (`DateTime.utc_now`) and a new-session-only `Ecto.UUID.generate` that never
  # fires under fixture replay. Both live BEFORE `id="chat-transcript"` in the DOM,
  # so scoping to everything FROM that marker onward (the existing `rail_html/1`
  # split pattern, chat_live_test.exs:3580 — transcript + composer + agents-rail)
  # yields a fully deterministic region across independent replay mounts.
  #
  # This is a CHARACTERISATION fixture (email_golden_test.exs doctrine): whatever
  # the region renders TODAY is correct by definition. `chat_render_golden.html`
  # was generated from this exact mount and committed verbatim. To legitimately
  # move it, regenerate in the SAME diff (`GOLDEN_REGEN=1 mix test <this file>`)
  # and justify why in review. A diff here means a render change leaked in.
  #
  # ── Fixture provenance (charter D62) ────────────────────────────────────────
  #
  #   * `epic_cycle_progress.ndjson` (wave 10, FROZEN): the real COMPLETED 7-phase
  #     29-agent node list (wf_49614704) — VERBATIM real-run payloads. Folded here
  #     through the SAME `rail_apply_background`/`rail_capture_progress` the
  #     Recorder uses, so the rail bytes are production-faithful.
  #   * `transcript_workday.ndjson` (NEW this slice): a minimal two-message
  #     transcript (user prompt + assistant markdown reply) so `message_body` — the
  #     paper-rendered assistant answer — is actually IN the byte-diff. Authored
  #     for render coverage (it is persisted markdown we round-trip through
  #     `FromMarkdown`/`Render`, NOT a wire capture); the VERBATIM-real law (D62)
  #     governs the RAIL node payloads above, which are real.

  @admin_token "chat-golden-admin-token"
  @fixtures_dir Path.expand("../../../fixtures/claude_chat", __DIR__)
  @golden_path Path.expand("chat_render_golden.html", __DIR__)
  @external_resource @golden_path

  # The wsc-wave sidebar byte-lock (charter D11) — a SECOND scoped region, the
  # SIDEBAR this time, pinned by its own golden. Same characterisation doctrine
  # as above; regenerate with GOLDEN_REGEN=1 in the same diff, justify in review.
  @sidebar_golden_path Path.expand("chat_sidebar_golden.html", __DIR__)
  @external_resource @sidebar_golden_path

  # Fixed session id ⇒ the new-session UUID path never fires; the id itself is a
  # constant in the region, so it stays byte-stable.
  @session_id "00000000-0000-4000-8000-0000000c0de0"

  # Sidebar-golden fixtures: one plain chat + one workflow (epic-cycle) session,
  # fixed ids and PINNED last_active_at ordering (newest first is the workflow
  # row). The wall-clock age labels these produce are sliced out (D11 — the
  # session_stamp text is the sidebar's only clock read).
  @plain_session_id "00000000-0000-4000-8000-0000000c0de1"
  @workflow_session_id "00000000-0000-4000-8000-0000000c0de2"

  defmodule NullTitleAdapter do
    def post(_url, _body, _headers), do: {:error, :disabled_in_tests}
  end

  defmodule NullTitleCli do
    def run(_binary, _args), do: {:error, :disabled_in_tests}
  end

  setup %{conn: conn} do
    # ── Wave-26 leaked-session pollution guard (felix-w27-s6) ─────────────────
    # The StudioChat Recorder is an app-tree GenServer (RuntimeSupervisor) that
    # can outlive a prior test's sandbox owner and COMMIT chat_sessions rows that
    # escape rollback. Such a leaked row renders as an EXTRA sidebar session card,
    # so the scoped SIDEBAR byte-lock below (D11) diverges from its pinned golden
    # — NOT a render change (the golden bytes are unmoved), just suite pollution.
    # At setup — before this test seeds its own sessions — every visible
    # chat_sessions row is such a leak, so purge them (restrict-FK children first,
    # then the sessions, which cascades messages / telemetry / leases). Rolls back
    # with the test transaction; test-infra hygiene only, ZERO prod code touched.
    Barkpark.Repo.query!("DELETE FROM chat_runtime_usage_receipts")
    Barkpark.Repo.query!("DELETE FROM epic_assignment_runtime_attempts")
    Barkpark.Repo.delete_all(Barkpark.StudioChat.Session)

    {:ok, _} =
      Auth.create_token(@admin_token, "chat golden admin", "production", [
        "read",
        "write",
        "admin"
      ])

    Application.put_env(:barkpark, :studio_chat_title_http_adapter, NullTitleAdapter)
    Application.put_env(:barkpark, :studio_chat_title_cli, NullTitleCli)

    prev_chat = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    # The tab is binary-presence gated (D4); a fake `cat` command satisfies the
    # gate. Reopen replays with NO spawn, so nothing is actually executed.
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    # Recorders are server-owned (wave 4) and OUTLIVE the LiveView — reap them at
    # test end so a lingering recorder can't touch the DB after the sandbox
    # connection is released (else a later test sees a Postgrex "client exited" +
    # FK errors). Mirrors chat_live_test.exs enable_fake_chat/0.
    on_exit(fn ->
      Barkpark.StudioChat.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)

        _ ->
          :ok
      end)
    end)

    on_exit(fn ->
      Application.delete_env(:barkpark, :studio_chat_title_http_adapter)
      Application.delete_env(:barkpark, :studio_chat_title_cli)

      if prev_chat,
        do: Application.put_env(:barkpark, :claude_chat, prev_chat),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
  end

  describe "scoped transcript+rail no-tax byte-lock (D66)" do
    test "the region renders byte-identical to the pinned golden", %{conn: conn} do
      seed_replay_session!()
      region = mount_region(conn)

      if System.get_env("GOLDEN_REGEN") == "1" do
        File.write!(@golden_path, region)
      end

      golden = File.read!(@golden_path)

      assert region == golden, """
      The scoped transcript+rail region diverged from the pinned golden.

      This is the wave-12 NO-TAX byte-lock (charter D66): introducing / wiring the
      Capabilities matrix must not move a single byte of Claude's render. A diff
      here means a render change leaked in.

      If the change is intentional, regenerate the golden in this SAME diff:

          GOLDEN_REGEN=1 mix test #{Path.relative_to_cwd(__ENV__.file)}

      and justify it in review.

      golden bytes:  #{byte_size(golden)}
      region bytes:  #{byte_size(region)}
      first diff at: #{first_diff_index(region, golden)}
      """
    end

    test "the region is byte-identical across two fully independent replay mounts (determinism guard)",
         %{conn: conn} do
      # D66's core empirical claim: the scoped region carries NO nondeterminism.
      # Seed ONCE, mount the SAME session twice — the scoped region never embeds
      # the session id (proven: 0 occurrences), so identical bytes = no clock /
      # randomness leaked into the locked region. If this fails, the byte-lock
      # above is a flake, not a moat.
      seed_replay_session!()
      assert mount_region(conn) == mount_region(conn)
    end

    test "the golden actually covers the transcript body AND the rail (guards a cleared fixture)" do
      golden = File.read!(@golden_path)
      assert byte_size(golden) > 1_000

      for needle <- [
            # the transcript body is inside the locked region (the `chat-transcript`
            # marker itself is the split delimiter and lives just before it)
            ~s(id="chat-messages"),
            # the NEW transcript fixture's message_body is in the diff (paper render,
            # not raw markdown — the heading became an <h2>, not literal "##")
            "Needs-you inbox",
            "bp-paper-surface",
            # the transcript ⊕ rail seam, then the rail itself
            "<!--rail-->",
            ~s(data-rail-task=)
          ] do
        assert String.contains?(golden, needle),
               "golden is missing coverage for: #{inspect(needle)}"
      end

      # the assistant markdown was RENDERED, never echoed as source
      refute String.contains?(golden, "## Needs-you inbox")
    end
  end

  describe "sidebar-scoped byte-lock (wsc charter D11)" do
    test "the sidebar region (stamps sliced) renders byte-identical to the pinned golden",
         %{conn: conn} do
      seed_sidebar_sessions!()
      region = mount_sidebar_region(conn)

      if System.get_env("GOLDEN_REGEN") == "1" do
        File.write!(@sidebar_golden_path, region)
      end

      golden = File.read!(@sidebar_golden_path)

      assert region == golden, """
      The scoped SIDEBAR region diverged from the pinned golden.

      This is the wsc-wave minimalism lock (charter D11): the two workflow lines
      exist ONLY on workflow rows, and every plain row's bytes are frozen. A diff
      here means a sidebar render change leaked in.

      If the change is intentional, regenerate the golden in this SAME diff:

          GOLDEN_REGEN=1 mix test #{Path.relative_to_cwd(__ENV__.file)}

      and justify it in review.

      golden bytes:  #{byte_size(golden)}
      region bytes:  #{byte_size(region)}
      first diff at: #{first_diff_index(region, golden)}
      """
    end

    test "the sidebar region is byte-identical across two independent mounts (determinism guard)",
         %{conn: conn} do
      seed_sidebar_sessions!()
      assert mount_sidebar_region(conn) == mount_sidebar_region(conn)
    end

    test "the golden covers both card lines AND a plain row (guards a cleared fixture)" do
      golden = File.read!(@sidebar_golden_path)

      for needle <- [
            # both rows are in the region
            ~s(data-test-id="chat-session-row"),
            "/studio/chat/#{@plain_session_id}",
            "/studio/chat/#{@workflow_session_id}",
            # line (a): ticks + settled counter on the workflow row only
            ~s(data-test-id="chat-workflow-#{@workflow_session_id}"),
            "complete · 29/29",
            "var(--life-done)",
            # line (b): the epic-goal line — title · slices · wave_status
            ~s(data-test-id="chat-epic-#{@workflow_session_id}"),
            "Wave Session Card",
            "1/3 slices",
            "wave: building 5 slices",
            # the wall clock is sliced, never frozen-in
            "<!--stamp-->"
          ] do
        assert String.contains?(golden, needle),
               "sidebar golden is missing coverage for: #{inspect(needle)}"
      end

      # the plain row carries NEITHER card line (D11 minimalism)…
      refute String.contains?(golden, "chat-workflow-#{@plain_session_id}")
      refute String.contains?(golden, "chat-epic-#{@plain_session_id}")
      # …and "PRs open" has no data source (D8) — never rendered
      refute String.contains?(golden, "PRs open")
    end
  end

  # ── per-agent drill-down affordance (wsc-ad) ────────────────────────────────
  #
  # The affordance attaches to agent ROWS, which render only under the active /
  # interrupted frontier phase — so the COMPLETED epic_cycle_progress golden above
  # (7 done phases, agents collapsed) shows NONE of it and stays byte-identical.
  # These tests seed a LIVE run instead so the rows (and their expand) are on
  # screen, then drive the toggle and assert the ABOUT / NOW markup — honest to the
  # wire, never a labeled thinking block.
  @drill_session_id "00000000-0000-4000-8000-0000000c0de3"
  @synth_session_id "00000000-0000-4000-8000-0000000c0de4"

  describe "rail agent drill-down affordance (wsc-ad D27/D29)" do
    test "a live run's agent row expands to its brief + live tool line, never 'thinking'",
         %{conn: conn} do
      # the interrupted fixture folded (NOT teardown-flipped) is a LIVE run: the
      # Explore frontier phase breathes with 4 non-terminal explorers whose rows
      # carry full detail.
      rail = fold_epic(load_ndjson("epic_cycle_interrupted.ndjson"))
      {:ok, _} = StudioChat.create_session(%{id: @drill_session_id, cwd: "/tmp", mode: "plan"})
      {:ok, _} = StudioChat.set_rail_snapshot(@drill_session_id, rail)

      # a non-terminal (active-phase) agent — the one actually rendered on screen
      agent = Enum.find(StudioChat.workflow_agent_detail(rail), &(not &1["terminal"]))
      assert is_binary(agent["agentId"])
      assert is_binary(agent["lastToolName"])

      {:ok, view, _html} = live(conn, "/studio/chat/#{@drill_session_id}")
      before = render(view)

      # the row shows the affordance but NOT the tool detail until expanded
      assert before =~ ~s(phx-click="rail-agent-toggle")
      assert before =~ ~s(phx-value-id="#{agent["agentId"]}")
      refute before =~ agent["lastToolName"]

      # drive the toggle for that specific agent
      after_html = render_click(view, "rail-agent-toggle", %{"id" => agent["agentId"]})

      # ABOUT (the brief) + NOW (the live '▸' tool line) are now on screen
      assert after_html =~ "about"
      assert after_html =~ "▸"
      assert after_html =~ agent["lastToolName"]
      # HONESTY: thinking text never rides the wire — nothing is labeled thinking
      refute after_html =~ "thinking"

      # collapse again — the detail folds away (default CLOSED, toggle wins)
      folded = render_click(view, "rail-agent-toggle", %{"id" => agent["agentId"]})
      refute folded =~ agent["lastToolName"]
    end

    test "attempt>1 renders a retry chip (D29 — explicitly synthetic node)", %{conn: conn} do
      # attempt>1 exists on NO real capture (rail_put_workflow is a bare Map.put,
      # barkpark forces no retry), so the chip is proven by a synthetic node — never
      # folded into the verbatim-from-real fixture.
      rail = %{
        "synth" => %{
          "seq" => 1,
          "status" => "running",
          "row" => %{"task_type" => "local_workflow", "description" => "synthetic wave"},
          "workflow" => [
            %{"type" => "workflow_phase", "index" => 1, "title" => "Build"},
            %{
              "type" => "workflow_agent",
              "phaseIndex" => 1,
              "agentId" => "synth-agent-1",
              "label" => "builder:retry",
              "state" => "start",
              "attempt" => 2,
              "promptPreview" => "You are the builder, retried…",
              "lastToolName" => "Edit",
              "lastToolSummary" => "re-applying the patch"
            }
          ]
        }
      }

      {:ok, _} = StudioChat.create_session(%{id: @synth_session_id, cwd: "/tmp", mode: "plan"})
      {:ok, _} = StudioChat.set_rail_snapshot(@synth_session_id, rail)

      {:ok, view, _html} = live(conn, "/studio/chat/#{@synth_session_id}")
      # the chip only shows once expanded
      refute render(view) =~ "attempt 2"

      expanded = render_click(view, "rail-agent-toggle", %{"id" => "synth-agent-1"})
      assert expanded =~ "attempt 2"
      assert expanded =~ "You are the builder, retried"
    end
  end

  # Two sessions: a plain chat and a settled epic-cycle workflow session whose
  # worker holds a slice under a published epic (the epic-goal line's ledger
  # chain). last_active_at is PINNED so row order never flaps.
  defp seed_sidebar_sessions!() do
    {:ok, _} = StudioChat.create_session(%{id: @plain_session_id, cwd: "/tmp", mode: "plan"})

    {:ok, _} =
      StudioChat.create_session(%{id: @workflow_session_id, cwd: "/tmp", mode: "plan"})

    rail = fold_epic(load_ndjson("epic_cycle_progress.ndjson"))
    {:ok, _} = StudioChat.set_rail_snapshot(@workflow_session_id, rail)

    pin_last_active!(@plain_session_id, ~U[2026-01-01 00:00:00.000000Z])
    pin_last_active!(@workflow_session_id, ~U[2026-01-02 00:00:00.000000Z])

    worker = BarkparkWeb.Studio.ClaudeChat.worker_id(@workflow_session_id)

    insert_ledger_task!("task-wsc-golden-epic", "Wave Session Card", %{
      "lifecycle_status" => "in_progress",
      "wave_status" => "wave: building 5 slices"
    })

    insert_ledger_task!("task-wsc-golden-held", "Slice s3", %{
      "lifecycle_status" => "in_progress",
      "parent_id" => "task-wsc-golden-epic",
      "claim" => %{"worker" => worker}
    })

    insert_ledger_task!("task-wsc-golden-s1", "Slice s1", %{
      "lifecycle_status" => "done",
      "parent_id" => "task-wsc-golden-epic"
    })

    insert_ledger_task!("task-wsc-golden-s2", "Slice s2", %{
      "lifecycle_status" => "open",
      "parent_id" => "task-wsc-golden-epic"
    })

    :ok
  end

  defp pin_last_active!(sid, at) do
    StudioChat.get_session(sid)
    |> Ecto.Changeset.change(last_active_at: at)
    |> Barkpark.Repo.update!()
  end

  defp insert_ledger_task!(doc_id, title, content) do
    Barkpark.Repo.insert!(%Barkpark.Content.Document{
      doc_id: doc_id,
      type: "task",
      title: title,
      status: "published",
      content: content,
      rev: Ecto.UUID.generate()
    })
  end

  # Mount the LIST route (no open session — no spawn, no transcript) and return
  # the scoped sidebar region: everything inside the 280px <aside>, with the
  # session_stamp wall-clock TEXT sliced to a comment (the sidebar's only clock
  # read — charter D11 names it the one legitimate slice).
  defp mount_sidebar_region(conn) do
    {:ok, view, _html} = live(conn, "/studio/chat")

    view
    |> render()
    |> scope_sidebar()
    |> sort_attrs()
    |> slice_stamps()
  end

  defp scope_sidebar(html) do
    html
    |> String.split(~s(<aside style="width: 280px))
    |> Enum.at(1, "")
    |> String.split("</aside>")
    |> List.first()
  end

  # ── Attribute-ORDER normalisation (the offset-723 flake) ───────────────────
  #
  # Phoenix prints a component's `:global` attributes by walking the `@rest`
  # MAP, and Erlang does not promise a map's iteration order — for a small map
  # it follows the internal ordering of the keys, which for atoms depends on
  # the order this VM happened to intern them. A `mix test` invocation that
  # also COMPILES the app interns its atoms in a different order than one that
  # runs against a warm `_build`, so the New-chat `<.link>` prints
  #
  #     class="btn btn-primary text-xs" style="display: inline-flex; …"
  #
  # on one boot and those same two attributes SWAPPED on the next — identical
  # attribute set, identical values, identical byte COUNT, first difference at
  # offset 723. Nothing about the render moved; only the order two attributes
  # were emitted in. That is the whole of this file's historical flake (the
  # region and the golden were always 6554 bytes).
  #
  # So: sort every element's attributes before the compare. The byte-lock keeps
  # pinning the attribute SET and every attribute VALUE, byte for byte; the one
  # thing it stops pinning is the intra-tag ORDER, which is not the render's to
  # promise. Runs BEFORE slice_stamps/1, which matches on a class⊕style pair.
  defp sort_attrs(html) do
    Regex.replace(
      ~r/<([a-zA-Z][-\w]*)((?:\s+[-\w:@.]+(?:="[^"]*")?)+)(\s*\/?)>/,
      html,
      fn _full, tag, attrs, tail ->
        sorted =
          ~r/[-\w:@.]+(?:="[^"]*")?/
          |> Regex.scan(attrs)
          |> Enum.map(&hd/1)
          |> Enum.sort()
          |> Enum.join(" ")

        "<" <> tag <> " " <> sorted <> tail <> ">"
      end
    )
  end

  # Both stamp spans (session row + needs-you strip row) share the exact
  # `margin-left: auto` style head — replace ONLY their text content.
  defp slice_stamps(html) do
    Regex.replace(
      ~r/(<span class="text-xs text-dim" style="margin-left: auto;(?: flex: none;)?">)[^<]*(<\/span>)/,
      html,
      "\\1<!--stamp-->\\2"
    )
  end

  # Seed ONE replayable session from the frozen fixtures: a persisted transcript
  # (message_body coverage) + a real-run rail snapshot. Idempotent within a test's
  # sandbox; call once, then mount as many times as the assertion needs.
  defp seed_replay_session!() do
    {:ok, _} = StudioChat.create_session(%{id: @session_id, cwd: "/tmp", mode: "plan"})

    for msg <- load_transcript("transcript_workday.ndjson") do
      {:ok, _} = StudioChat.append_message(@session_id, msg)
    end

    rail = fold_epic(load_ndjson("epic_cycle_progress.ndjson"))
    {:ok, _} = StudioChat.set_rail_snapshot(@session_id, rail)
    :ok
  end

  # Mount the seeded session (replay, NO spawn) and return the scoped region.
  defp mount_region(conn) do
    [{tid, _entry}] = Map.to_list(fold_epic(load_ndjson("epic_cycle_progress.ndjson")))

    {:ok, view, _html} = live(conn, "/studio/chat/#{@session_id}")

    # A completed cycle defaults collapsed (D61) — open it so the full journey is
    # in the byte-lock, not just the aggregate header.
    unless render(view) =~ "data-rail-phase" do
      render_click(element(view, ~s([phx-click="rail-toggle"][phx-value-id="#{tid}"])))
    end

    scope(render(view))
  end

  # The locked region = the transcript container's BODY  ⊕  the agents-rail —
  # D66's two named anchors (`id="chat-transcript"` / `data-role="agents-rail"`).
  # The COMPOSER, which sits between them, is deliberately sliced OUT: its
  # LiveView file-upload input mints a fresh `data-phx-upload-ref` per mount (the
  # one nondeterminism source in this stretch — a random ref, not a clock). The
  # sidebar (the file's other clock/randomness surface) sits BEFORE the transcript
  # and is excluded by construction. The studio-shell FOOTER, which trails the
  # rail, is sliced OUT too: `#bp-build-version` embeds compile-time git data
  # (version · commit SHA), so a golden that swallows it goes red on every new
  # commit — the SHA is build provenance, not Claude's render (reviewer fix,
  # wave 12). What remains — Claude's rendered transcript body + the
  # mission-control rail — is fully deterministic across mounts AND commits.
  defp scope(html) do
    transcript =
      html
      |> String.split(~s(id="chat-transcript"))
      |> Enum.at(1, "")
      |> String.split(~s(<div class="bp-composer"))
      |> List.first()

    rail =
      html
      |> String.split(~s(data-role="agents-rail"))
      |> List.last()
      |> String.split(~s(<div class="studio-footer"))
      |> List.first()

    sort_attrs(transcript <> "\n<!--rail-->\n" <> rail)
  end

  defp load_transcript(name) do
    load_ndjson(name)
    |> Enum.map(fn m -> %{role: m["role"], source_markdown: m["source_markdown"]} end)
  end

  defp load_ndjson(name) do
    @fixtures_dir
    |> Path.join(name)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp fold_epic(frames) do
    Enum.reduce(frames, %{}, fn f, rail ->
      case f["subtype"] do
        "background_tasks_changed" -> StudioChat.rail_apply_background(rail, f)
        "task_progress" -> StudioChat.rail_capture_progress(rail, f)
        _ -> rail
      end
    end)
  end

  defp first_diff_index(a, b) do
    a = :binary.bin_to_list(a)
    b = :binary.bin_to_list(b)

    Enum.zip(a, b)
    |> Enum.find_index(fn {x, y} -> x != y end)
    |> case do
      nil -> min(length(a), length(b))
      i -> i
    end
  end
end
