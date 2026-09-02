defmodule BarkparkWeb.Studio.ChatContextBandTest do
  @moduledoc """
  chat-local-cloud-context-w3 criterion 2 — the STUDIO half of the chat context
  identity. The CLI half shipped as `internal/chat/context.go` +
  `internal/chat/context_test.go`; this suite is its mirror, and it keeps the
  same three shapes deliberately:

    * every assertion reads the RENDERED band (Floki text off the live DOM),
      never a format string and never the struct — a band that resolves
      perfectly and paints nothing would pass a struct-only suite;
    * the mismatch runs write their failure message BEFORE the assertion, and
      the message names BOTH values it demands. A band that hardcoded either
      one still reds, because the other value exists only in a table the
      hardcoded string could not have read;
    * fields are addressed BY NAME (`data-test-id="chat-context-<name>"`), never
      by position — a reordered band must not silently re-point an assertion.

  `async: false`: these mounts share the seeded Default workspace and the
  chat-runtime application env, exactly like `chat_live_test.exs`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.ContextIdentity
  alias Barkpark.StudioChat.Runtime.Command
  alias Barkpark.Tenancy

  setup %{conn: conn} do
    # Same wave-26 leak guard chat_live_test.exs carries: a Recorder that
    # outlived a prior test can commit chat_sessions rows that escape rollback
    # and ride list_sessions' recency ordering into this suite's sidebar.
    Barkpark.Repo.query!("DELETE FROM chat_runtime_usage_receipts")
    Barkpark.Repo.query!("DELETE FROM epic_assignment_runtime_attempts")
    Barkpark.Repo.delete_all(Barkpark.StudioChat.Session)

    enable_fake_chat()
    put_probe({:static, :ready})

    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "ctxb-ws-#{n}", name: "CtxBand #{n}"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "ctxb-proj-#{n}", name: "CtxBand Proj"})

    # `create_token/5` writes the workspace membership itself, and
    # `TenancyAuth.role_for_permissions/1` grades an admin-permissioned token to
    # an ADMIN membership — which is what the `/w/:ws/p/:proj/studio/chat`
    # scoped mount gates on. A second create_membership/3 here would only hit
    # the principal-unique index.
    raw = "ctxb-admin-#{n}"

    {:ok, _token} =
      Auth.create_token(raw, "ctxb admin", "production", ~w(read write admin), ws.id)

    {:ok, conn: init_test_session(conn, %{"api_token" => raw}), ws: ws, proj: proj, n: n}
  end

  # ── criterion 1: the band names all six, on the open session ────────────────

  describe "the context band on an open session" do
    test "names the execution host, server, workspace, project, dataset and repository root",
         %{conn: conn, ws: ws, proj: proj, n: n} do
      host = enroll!(ws, "alpha-#{n}")
      sid = host_session!(ws, host, "/srv/checkout-#{n}")
      lease!(host, sid)

      {:ok, _view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/studio/chat/#{sid}")

      assert html =~ ~s(data-test-id="chat-context-band")

      # The rendered band, verbatim — this is the evidence, not the template.
      assert band(html, "host") == "host alpha-#{n}"
      assert band(html, "server") == "server #{BarkparkWeb.Endpoint.url()}"
      assert band(html, "workspace") == "workspace #{ws.slug}"
      assert band(html, "project") == "project #{proj.slug}"

      # DATASET: no chat route carries a `:dataset` segment, so ChatLive runs on
      # a dataset it substituted for itself. The absence is the headline and the
      # substitution is reported — printing "production" alone here would be the
      # plausible-default lie the CLI half exists to prevent.
      assert band(html, "dataset") =~ "dataset (not set) — the chat mount substitutes"

      # REPOSITORY ROOT on a registered host: a HOST-side fact the chat-host
      # protocol does not carry (a host declares name / approved_roots /
      # provider capabilities and then emits events — never a work-tree root).
      assert band(html, "repo") ==
               "repo (unknown) — \"/srv/checkout-#{n}\" on the execution host, " <>
                 "which reports no repository root"
    end

    test "every named field is present exactly once and none renders blank", %{
      conn: conn,
      ws: ws,
      n: n
    } do
      host = enroll!(ws, "alpha-#{n}")
      sid = host_session!(ws, host, "/srv/checkout-#{n}")
      lease!(host, sid)

      {:ok, _view, html} = live(conn, "/studio/chat/#{sid}")

      for name <- ContextIdentity.field_names() do
        found = count_segments(html, ~s([data-test-id="chat-context-#{name}"]))

        assert found == 1,
               "the band must carry exactly one #{name} segment, addressable by name; " <>
                 "found #{found}"

        rendered = band(html, name)

        # The whole point of the typed-absence law: a segment that rendered its
        # name and then nothing is the failure this band exists to prevent.
        assert String.trim(String.replace_prefix(rendered, name, "")) != "",
               "the #{name} segment rendered its label and NOTHING: #{inspect(rendered)}"
      end
    end
  end

  # ── criterion 2: the mismatch fixtures ──────────────────────────────────────

  describe "mismatch — the band reports a disagreement instead of hiding it" do
    test "a lease held by host B while the last report came from host A names BOTH", %{
      conn: conn,
      ws: ws,
      n: n
    } do
      alpha = enroll!(ws, "alpha-#{n}")
      beta = enroll!(ws, "beta-#{n}")
      sid = host_session!(ws, alpha, "/srv/checkout-#{n}")

      # Host alpha ran the session and reported an event under its own fence…
      alpha_fence = lease!(alpha, sid)
      report_event!(alpha, alpha_fence)

      # …then execution TRANSFERRED: beta now holds the live lease. Nothing in
      # the session row records this; the disagreement exists only between the
      # leases table and the events table, which is exactly why a band that
      # reads one of them alone would answer confidently and wrongly.
      lease!(beta, sid)

      {:ok, _view, html} = live(conn, "/studio/chat/#{sid}")
      rendered = band(html, "host")

      # WRITTEN BEFORE THE ASSERTION. It cannot read the same for a hardcoded
      # value: it demands the lease holder AND the last reporter, and the last
      # reporter's name exists ONLY in chat_execution_events — a band that
      # hardcoded, or read only, the lease holder can never satisfy it.
      message = """
      the host field must REPORT the lease/report disagreement, naming both hosts.
        lease holder (the headline): #{beta.name}
        last reporter (the report):  #{alpha.name}
        rendered:                    #{inspect(rendered)}
      """

      assert String.contains?(rendered, beta.name), message
      assert String.contains?(rendered, alpha.name), message
      assert String.contains?(rendered, "⚠"), message
      assert has_element_with_mismatch?(html, "host"), message
    end

    test "a session owned by a different workspace than the viewer's names BOTH", %{
      conn: conn,
      ws: ws,
      n: n
    } do
      {:ok, other} = Tenancy.create_workspace(%{slug: "ctxb-other-#{n}", name: "Other #{n}"})
      sid = managed_session!(other, nil)

      # The FLAT mount: no URL scope, so the viewer's workspace is the acting
      # token's own (`ws`), and the tenancy clamp is open — which is precisely
      # the mount on which a foreign-workspace session can be opened at all.
      {:ok, _view, html} = live(conn, "/studio/chat/#{sid}")
      rendered = band(html, "workspace")

      message = """
      the workspace field must REPORT the scope disagreement, naming both workspaces.
        session's own workspace (the headline): #{other.slug}
        viewer's workspace (the claim):         #{ws.slug}
        rendered:                               #{inspect(rendered)}
      """

      assert String.contains?(rendered, other.slug), message
      assert String.contains?(rendered, ws.slug), message
      assert String.contains?(rendered, "⚠"), message
      assert has_element_with_mismatch?(html, "workspace"), message
    end

    test "an agreeing workspace carries NO warning — the ⚠ is not decoration", %{
      conn: conn,
      ws: ws
    } do
      sid = managed_session!(ws, nil)

      {:ok, _view, html} = live(conn, "/studio/chat/#{sid}")

      assert band(html, "workspace") == "workspace #{ws.slug}"
      refute has_element_with_mismatch?(html, "workspace")
    end
  end

  # ── criterion 3: typed absence + reconnect ──────────────────────────────────

  describe "typed absence" do
    test "no lease → the host field says (server-local), not blank and not a host name", %{
      conn: conn,
      ws: ws
    } do
      sid = managed_session!(ws, nil)

      {:ok, _view, html} = live(conn, "/studio/chat/#{sid}")

      assert band(html, "host") == "host (server-local)"
    end

    test "a cwd outside a git work tree → (not a git repo), measured by the real probe", %{
      conn: conn,
      ws: ws,
      n: n
    } do
      dir = Path.join(System.tmp_dir!(), "bp-ctxb-#{n}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      # No probe injected: this run drives the REAL `git rev-parse
      # --show-toplevel`, so the vocabulary it proves is reachable in
      # production rather than a constant a fake handed back.
      refute git_repo?(dir)
      sid = managed_session!(ws, dir)

      {:ok, _view, html} = live(conn, "/studio/chat/#{sid}")

      assert band(html, "repo") == "repo (not a git repo)"
    end

    test "a cwd inside a work tree → the toplevel, again from the real probe", %{
      conn: conn,
      ws: ws
    } do
      cwd = File.cwd!()
      {:ok, root} = ContextIdentity.git_toplevel(cwd)
      sid = managed_session!(ws, cwd)

      {:ok, _view, html} = live(conn, "/studio/chat/#{sid}")

      assert band(html, "repo") == "repo #{root}"
    end

    test "the new-chat state: no cwd → repo (not set); the dataset stays a reported substitution",
         %{conn: conn, proj: proj} do
      {:ok, _view, html} = live(conn, "/studio/chat")

      # No session row → no working directory to measure. `(not set)` is the
      # measured absence; the probe is never run and never guesses.
      assert band(html, "repo") == "repo (not set)"

      # The dataset is STILL the mount's own substitution even with nothing
      # open — the flat route carries no `:dataset`, so the absence is the
      # headline here exactly as it is on an open session.
      assert band(html, "dataset") =~ "dataset (not set) — the chat mount substitutes"

      # The project is genuinely resolvable on the flat mount (StudioChrome's
      # `derive_scope_from_principal/1` reads it off the acting token), so the
      # band names it rather than claiming an absence that is not there.
      # `(not set)` for a project that truly is absent is pinned at the
      # resolver, below — it cannot be staged through this mount.
      assert band(html, "project") == "project #{proj.slug}"
    end

    test "an absent project resolves to (not set) — never blank, never a stand-in" do
      identity =
        ContextIdentity.resolve(%{
          endpoint: "http://example.test",
          viewer_workspace: "ws",
          session_workspace: "ws",
          project: nil,
          scope_dataset: nil,
          mount_dataset: nil,
          execution_target: "managed",
          cwd: nil
        })

      for {name, expected} <- [
            {"host", "(server-local)"},
            {"project", "(not set)"},
            {"dataset", "(not set)"},
            {"repo", "(not set)"}
          ] do
        field = ContextIdentity.field(identity, name)

        assert ContextIdentity.Field.display(field) == expected,
               "#{name} must render #{expected} for a measured absence, got " <>
                 inspect(ContextIdentity.Field.display(field))
      end
    end

    test "a probe that cannot answer is (unknown), which is NOT the same as (not a git repo)" do
      identity =
        ContextIdentity.resolve(%{
          execution_target: "managed",
          cwd: "/somewhere",
          repo_probe: fn _ -> {:error, :unknown} end
        })

      assert ContextIdentity.Field.display(ContextIdentity.field(identity, "repo")) == "(unknown)"

      determinate =
        ContextIdentity.resolve(%{
          execution_target: "managed",
          cwd: "/somewhere",
          repo_probe: fn _ -> {:error, :not_a_repo} end
        })

      assert ContextIdentity.Field.display(ContextIdentity.field(determinate, "repo")) ==
               "(not a git repo)"
    end

    test "the four markers are distinct strings — an operator can tell them apart" do
      markers = [
        ContextIdentity.unset_marker(),
        ContextIdentity.unknown_marker(),
        ContextIdentity.no_repo_marker(),
        ContextIdentity.server_local_marker()
      ]

      assert markers == Enum.uniq(markers)
      assert Enum.all?(markers, &String.starts_with?(&1, "("))
    end
  end

  describe "reconnect" do
    test "a lease transfer + host re-report updates the band IN PLACE, no remount", %{
      conn: conn,
      ws: ws,
      n: n
    } do
      alpha = enroll!(ws, "alpha-#{n}")
      beta = enroll!(ws, "beta-#{n}")
      sid = host_session!(ws, alpha, "/srv/checkout-#{n}")
      lease!(alpha, sid)

      {:ok, view, html} = live(conn, "/studio/chat/#{sid}")
      assert band(html, "host") == "host alpha-#{n}"

      # The transfer, then beta speaking under its OWN fence — the real
      # `ChatHosts.report_state/4`, which broadcasts on the activity topic this
      # LiveView already joined (no new subscription, no reconnect).
      beta_fence = lease!(beta, sid)
      {:ok, _} = ChatHosts.report_state(beta, sid, "working", beta_fence.epoch)

      after_report = band(render(view), "host")

      assert after_report == "host beta-#{n}",
             "a host report must refresh the band in place through the existing " <>
               "activity-topic path; the header still reads #{inspect(after_report)}"
    end
  end

  # ── the by-name plumbing guard (mirrors the CLI's Field-by-name lookup) ─────

  describe "field lookup" do
    test "resolve/1 answers by NAME, so a reordered band cannot re-point a reader" do
      identity =
        ContextIdentity.resolve(%{
          lease_host: "alpha",
          reporting_host: "alpha",
          endpoint: "http://example.test",
          viewer_workspace: "ws",
          session_workspace: "ws",
          project: "proj",
          scope_dataset: "ds",
          mount_dataset: "ds",
          execution_target: "managed",
          cwd: "/x",
          repo_probe: fn _ -> {:error, :not_a_repo} end
        })

      assert Enum.map(identity.fields, & &1.name) == ContextIdentity.field_names()

      for name <- ContextIdentity.field_names() do
        assert %{name: ^name} = ContextIdentity.field(identity, name)
      end

      assert ContextIdentity.field(identity, "hostname") == nil
      assert ContextIdentity.mismatches(identity) == []
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # The RENDERED text of one band segment, addressed by name. LazyHTML (the
  # parser Phoenix.LiveViewTest itself uses) unescapes the entities HEEx wrote
  # (`&quot;` back to `"`), so every assertion above reads the string a HUMAN
  # sees — not the markup, and certainly not the format string.
  defp band(html, name) do
    html
    |> segments(~s([data-test-id="chat-context-#{name}"]))
    |> LazyHTML.text()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp segments(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  end

  defp count_segments(html, selector) do
    html |> segments(selector) |> Enum.count()
  end

  defp has_element_with_mismatch?(html, name) do
    count_segments(html, ~s([data-test-id="chat-context-#{name}"][data-mismatch="true"])) > 0
  end

  defp git_repo?(dir) do
    match?({:ok, _}, ContextIdentity.git_toplevel(dir))
  end

  defp enroll!(ws, name) do
    {:ok, %{enrollment_token: token}} = ChatHosts.issue_enrollment(ws.id, %{name: name})
    {:ok, %{credential: credential}} = ChatHosts.enroll(token)
    {:ok, host} = ChatHosts.authenticate(credential)
    host
  end

  defp lease!(host, sid) do
    command = %Command{
      operation: :start,
      provider: "claude",
      session_id: sid,
      idempotency_key: "ctxb-#{System.unique_integer([:positive])}",
      payload: %{}
    }

    {:ok, fence} = ChatHosts.lease_and_enqueue(host, command, [])
    fence
  end

  # One real, fenced host event — the row `session_execution_identity/1` reads
  # as "who last reported". Written through `accept_event/2`, the production
  # path, so the fixture cannot drift from the shape a host actually writes.
  defp report_event!(host, fence) do
    {:ok, :accepted} =
      ChatHosts.accept_event(host, %{
        lease_id: fence.lease_id,
        epoch: fence.epoch,
        cursor: 1,
        idempotency_key: "ctxb-ev-#{System.unique_integer([:positive])}",
        event: %{"kind" => "turn_started"}
      })

    :ok
  end

  defp host_session!(ws, host, cwd) do
    sid = Ecto.UUID.generate()

    {:ok, _} =
      StudioChat.create_session(
        %{
          id: sid,
          mode: "plan",
          cwd: cwd,
          execution_target: "registered_host",
          execution_host_id: host.id,
          provider_session_id: sid
        },
        {:workspace, ws.id}
      )

    sid
  end

  defp managed_session!(ws, cwd) do
    sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: sid, mode: "plan", cwd: cwd}, {:workspace, ws.id})
    sid
  end

  defp enable_fake_chat do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)

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

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)
  end

  defp put_probe(value) do
    prev = Application.get_env(:barkpark, :studio_chat_readiness_probe)
    Application.put_env(:barkpark, :studio_chat_readiness_probe, value)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :studio_chat_readiness_probe, prev),
        else: Application.delete_env(:barkpark, :studio_chat_readiness_probe)
    end)
  end
end
