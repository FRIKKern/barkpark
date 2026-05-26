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
