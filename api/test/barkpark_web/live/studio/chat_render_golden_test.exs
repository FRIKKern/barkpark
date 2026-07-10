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

  # Fixed session id ⇒ the new-session UUID path never fires; the id itself is a
  # constant in the region, so it stays byte-stable.
  @session_id "00000000-0000-4000-8000-0000000c0de0"

  defmodule NullTitleAdapter do
    def post(_url, _body, _headers), do: {:error, :disabled_in_tests}
  end

  defmodule NullTitleCli do
    def run(_binary, _args), do: {:error, :disabled_in_tests}
  end

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "chat golden admin", "production", ["read", "write", "admin"])

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

    transcript <> "\n<!--rail-->\n" <> rail
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
