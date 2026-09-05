defmodule BarkparkCloud.Web.AuthGateNameCensusTest do
  @moduledoc """
  A SOURCE CENSUS that keeps a retired gate NAME from resurfacing.

  `Auth.require_current_team_admin/1` and `Auth.require_current_team_owner/1`
  were once named `require_primary_team_*`. That name asserted a scope the code
  never enforced: both read `conn.assigns[:current_team]`, which `require_user/2`
  fills via `resolve_team/2` — the `x-barkpark-team` header wins whenever the
  caller is a member of that team, and primary membership is only the fallback.
  Every refusal the two gates emit already says `scope: "team"` for that reason.

  A `@doc` said so and the NAME kept saying otherwise, and a cold agent greps
  the identifier, not the doc. So the name moved, and this file is what stops it
  moving back: a rename that reaches only SOME of the tree leaves the retired
  identifier alive in comments, fixtures and census tables, and the next reader
  believes the half that is louder.

  WHAT IT SCANS: `cloud/lib`, `cloud/priv/static` and `cloud/test` — the whole
  live-code fence, source AND prose, because the defect this pins is a NAME a
  human reads, and a comment carries a name just as well as a call does. Ledger
  records under `tooling/grip/`, charters under `.claude/workflows/` and the Go
  comments under `internal/` are deliberately OUT of scope: those are dated
  evidence and cross-fence trees, and rewriting a dated record falsifies it.

  ANTI-VACUITY: the scan asserts a non-empty file population AND that the NEW
  names are present, so a wrong root (which would make the retired-name census
  trivially empty and green) fails instead of passing.

  The retired identifier is spelled by concatenation here so that this file is
  not its own last surviving occurrence.
  """
  use ExUnit.Case, async: true

  @fence_root Path.expand("../../..", __DIR__)

  @scanned_globs [
    "lib/**/*.{ex,exs}",
    "priv/static/*.{js,mjs}",
    "priv/static/__preview__/*.mjs",
    "test/**/*.{ex,exs}"
  ]

  # Split so this census does not match itself.
  @retired ["require_" <> "primary_team_admin", "require_" <> "primary_team_owner"]
  @current ["require_current_team_admin", "require_current_team_owner"]

  defp files do
    @scanned_globs
    |> Enum.flat_map(&Path.wildcard(Path.join(@fence_root, &1)))
    |> Enum.reject(&(&1 == Path.expand(__ENV__.file)))
    |> Enum.uniq()
  end

  test "the fence population is non-empty (a wrong root cannot green this file)" do
    all = files()

    assert length(all) > 100,
           "expected the cloud fence to hold >100 scanned files, got #{length(all)}"

    assert Enum.any?(all, &String.ends_with?(&1, "lib/barkpark_cloud/web/auth.ex"))
    assert Enum.any?(all, &String.ends_with?(&1, "priv/static/app.js"))
  end

  test "the CURRENT gate names are actually present (the census has something to be about)" do
    corpus = files() |> Enum.map(&File.read!/1) |> Enum.join("\n")

    for name <- @current do
      assert String.contains?(corpus, name), "expected #{name} somewhere in the cloud fence"
    end
  end

  test "the retired primary-team gate names appear NOWHERE in the cloud fence" do
    offenders =
      for path <- files(),
          body = File.read!(path),
          name <- @retired,
          String.contains?(body, name) do
        rel = Path.relative_to(path, @fence_root)

        hits =
          body
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} -> String.contains?(line, name) end)
          |> Enum.map(fn {_, n} -> n end)

        "#{rel} carries #{name} on line(s) #{Enum.join(hits, ", ")}"
      end

    assert offenders == [],
           """
           A retired gate name is back in the cloud fence.

           #{Enum.join(offenders, "\n")}

           Both gates judge conn.assigns[:current_team] — the team the caller
           currently has selected, which the x-barkpark-team header decides
           whenever the caller is a member of it. Primary membership is only the
           fallback, so a "primary_team" name is a claim the code does not make.
           Use require_current_team_admin/1 and require_current_team_owner/1.
           """
  end
end
