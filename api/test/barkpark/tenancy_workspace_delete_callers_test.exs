defmodule Barkpark.TenancyWorkspaceDeleteCallersTest do
  @moduledoc """
  Static-analysis regression that asserts NO production code in `lib/` calls
  `Repo.delete/1` (or `Repo.delete!/1`) directly on a `Workspace` — every
  workspace-delete call site MUST route through
  `Barkpark.Tenancy.delete_workspace/1` so the blob/CDN/plugin cleanup
  pass fires before the SQL delete + CASCADE.

  Background (rs2j, closing obhg): the obhg fix introduced
  `Tenancy.delete_workspace/1` as the canonical path — it walks
  `media_files` (Media.delete_file → File.rm + Cdn.invalidate +
  `:after_media_delete` hook) and `documents` (Content.delete_document
  → `:before/after_document_delete` hooks) BEFORE `Repo.delete(workspace)`.
  Any caller that calls `Repo.delete(workspace)` directly bypasses the
  cleanup → reintroduces the orphan-blob / orphan-CDN-cache leak.

  This test parses every `.ex` file under `lib/` into an AST and walks
  for `Repo.delete(... workspace ...)` calls outside the single
  legitimate site (`Barkpark.Tenancy.do_delete_workspace/1`). The AST
  walk means moduledoc text that REFERENCES `Repo.delete(workspace)` in
  a code block (e.g. the warning on `Tenancy.Workspace`) does not trip
  the check — only real call expressions do.
  """
  use ExUnit.Case, async: true

  @lib_dir Path.expand("../../lib", __DIR__)

  test "no caller in lib/ invokes Repo.delete on a Workspace outside Tenancy.delete_workspace/1" do
    files = Path.wildcard(Path.join(@lib_dir, "**/*.ex"))

    offenders =
      for file <- files,
          {:ok, ast} <- [parse(file)],
          call <- find_repo_delete_workspace_calls(ast),
          not allowed?(file, call) do
        {Path.relative_to(file, @lib_dir), call.line, call.snippet}
      end

    assert offenders == [], """
    Found Repo.delete(workspace) call sites in lib/ that BYPASS the canonical
    Tenancy.delete_workspace/1 cleanup path. Each such caller will leak blobs
    (no File.rm), miss the CDN purge, and skip plugin hooks
    (:after_media_delete, :before_document_delete, :after_document_delete).

    Offenders:
    #{Enum.map_join(offenders, "\n", fn {f, ln, s} -> "  #{f}:#{ln}  #{s}" end)}

    Fix: replace `Repo.delete(workspace)` with
    `Barkpark.Tenancy.delete_workspace(workspace)`.
    """
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp parse(file) do
    case Code.string_to_quoted(File.read!(file), columns: true) do
      {:ok, ast} -> {:ok, ast}
      # If a file fails to parse, the project wouldn't compile — but be
      # defensive so this regression test doesn't mask a real error.
      _ -> :error
    end
  end

  # Walk the AST collecting `Repo.delete(arg)` / `Repo.delete!(arg)` calls
  # where the argument's source text mentions a workspace variable or struct.
  defp find_repo_delete_workspace_calls(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Repo]}, fun]}, meta, [arg]} = node, acc
        when fun in [:delete, :delete!] ->
          if looks_like_workspace?(arg) do
            line = Keyword.get(meta, :line, 0)
            {node, [%{line: line, snippet: Macro.to_string(node)} | acc]}
          else
            {node, acc}
          end

        other, acc ->
          {other, acc}
      end)

    Enum.reverse(acc)
  end

  # Heuristic on the AST argument: does it look like a workspace?
  # Matches:
  #   workspace          (var)
  #   %Workspace{}       / %Workspace{...}
  #   %Tenancy.Workspace{...}
  #   ws / wsp           (common short forms)
  defp looks_like_workspace?(arg) do
    src = Macro.to_string(arg)
    Regex.match?(~r/\b[Ww]orkspace\b/, src) or Regex.match?(~r/^\s*ws\b/, src)
  end

  # The ONE legitimate site: Tenancy.do_delete_workspace/1 in lib/barkpark/tenancy.ex.
  # We don't pin to a specific line — any Repo.delete(workspace) call inside
  # that file is allowed, because that module OWNS the canonical path. Every
  # other file is forbidden.
  defp allowed?(file, _call) do
    String.ends_with?(file, "/barkpark/tenancy.ex")
  end
end

defmodule Barkpark.TenancyWorkspaceDeleteAuditSweepTest do
  @moduledoc """
  bl-audit-fk-orphans — proves how `Tenancy.delete_workspace/1` treats the two
  FK-less audit tables that carry `workspace_id` as a plain binary_id with ZERO
  foreign key (migrations 20260705120000 / 20260705140000), which the SQL
  CASCADE on `Repo.delete(workspace)` therefore can NEVER reach.

  Recorded posture (charter D4/D5):

    * `audit_export_sinks` — SWEPT. A plain mutable config table (no trigger,
      no FK) holding SIEM endpoint URLs + secrets; it must not outlive the
      workspace, so `do_delete_workspace/1` runs an explicit workspace-scoped
      `Repo.delete_all`.
    * `audit_events` — RETAINED BY DESIGN. The append-only, tamper-evident,
      per-workspace sha256 hash chain is protected by a DB-level
      `BEFORE UPDATE OR DELETE` trigger (`audit_events_no_update_delete`) that
      RAISES on any delete. Deleting it would defeat the guarantee the chain
      exists to provide, so a torn-down workspace's audit trail is intentionally
      kept for forensics/compliance — orphaned of its workspace row by decision,
      not by neglect.

  Either way there is NO SILENT orphaning: sinks go, audit history is a recorded,
  deliberate retention. This test asserts both, and that the target workspace's
  sweep leaves a SECOND workspace's audit rows and sinks untouched.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Audit
  alias Barkpark.Audit.{Event, ExportSink}
  alias Barkpark.Tenancy

  defp make_workspace(name) do
    slug = "ws-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, ws} = Tenancy.create_workspace(%{name: name, slug: slug})
    ws
  end

  defp count_events(ws_id),
    do: Repo.aggregate(from(e in Event, where: e.workspace_id == ^ws_id), :count)

  defp count_sinks(ws_id),
    do: Repo.aggregate(from(s in ExportSink, where: s.workspace_id == ^ws_id), :count)

  test "delete_workspace sweeps audit_export_sinks, retains audit_events, and is workspace-scoped" do
    target = make_workspace("Teardown Target")
    bystander = make_workspace("Bystander")

    # Audit history for BOTH workspaces (Audit.emit is the append-only writer).
    {:ok, %Event{}} = Audit.emit(%{category: "auth", action: "login_succeeded", workspace_id: target.id, actor_id: "u1"})
    {:ok, %Event{}} = Audit.emit(%{category: "auth", action: "session_revoked", workspace_id: target.id, actor_id: "u1"})
    {:ok, %Event{}} = Audit.emit(%{category: "auth", action: "login_succeeded", workspace_id: bystander.id, actor_id: "u2"})

    # A SIEM export sink for BOTH workspaces.
    {:ok, %ExportSink{}} =
      Barkpark.Audit.Export.create_sink(%{
        name: "target-splunk",
        url: "https://splunk.example.com/target",
        workspace_id: target.id
      })

    {:ok, %ExportSink{}} =
      Barkpark.Audit.Export.create_sink(%{
        name: "bystander-splunk",
        url: "https://splunk.example.com/bystander",
        workspace_id: bystander.id
      })

    assert count_events(target.id) == 2
    assert count_sinks(target.id) == 1
    assert count_events(bystander.id) == 1
    assert count_sinks(bystander.id) == 1

    # Teardown must succeed — a plain DELETE FROM audit_events would RAISE on the
    # immutability trigger, so a clean {:ok, _} also proves we do NOT touch it.
    assert {:ok, %Tenancy.Workspace{}} = Tenancy.delete_workspace(target)

    # audit_export_sinks: swept for the target, untouched for the bystander.
    assert count_sinks(target.id) == 0
    assert count_sinks(bystander.id) == 1

    # audit_events: RETAINED for the torn-down workspace (recorded posture),
    # and the bystander's chain is untouched.
    assert count_events(target.id) == 2
    assert count_events(bystander.id) == 1

    # The workspace row itself is gone.
    assert Tenancy.get_workspace_by_id(target.id) == nil
  end
end
