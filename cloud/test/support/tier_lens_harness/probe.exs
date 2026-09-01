# The same rows as rows.exs, grouped BY the guard they resolve to.
#
#     elixir cloud/test/support/tier_lens_harness/probe.exs \
#       cloud/test/support/router_tier_lens.ex \
#       cloud/lib/barkpark_cloud/web/router.ex
#
# WHY GROUPING IS THE USEFUL VIEW. A per-row listing shows disagreements one
# at a time; grouping shows a whole route FAMILY that has collapsed onto a
# single guard. That is the shape of the defect #14477 fixed: eleven
# `with_team_site` routes all resolving to `require_user` regardless of the
# auth mode each one actually passed, because the lens returned the first
# `Auth.require_*` it met in the delegated helper. Counted per row, that reads
# as eleven ordinary rows; grouped, it reads as one bucket that has swallowed
# a family — which is visible at a glance and hard to unsee.
#
# So: read this one when you suspect the lens is under-resolving, and rows.exs
# when you need a specific row named. A bucket far larger than its siblings is
# the tell.

lens = System.argv() |> Enum.at(0)
router = System.argv() |> Enum.at(1)

unless lens && router && File.exists?(lens) && File.exists?(router) do
  IO.puts(:stderr, "usage: elixir probe.exs <router_tier_lens.ex> <router.ex>")
  System.halt(2)
end

Code.compile_file(lens)
alias BarkparkCloud.RouterTierLens, as: Lens

src = File.read!(router)
[_, block] = Regex.run(~r/@moduledoc\s+"""(.*?)"""/s, src)
row_re = ~r/^\s{4,}(GET|POST|PUT|PATCH|DELETE)\s+(\S+)\s+(\S+)/
tokens = Lens.tier_tokens()

rows =
  block
  |> String.split("\n")
  |> Enum.flat_map(fn line ->
    case Regex.run(row_re, line) do
      [_, m, p, t] -> if t in tokens, do: [{m, p, t}], else: []
      _ -> []
    end
  end)

IO.puts("tier-bearing rows: #{length(rows)}")

by_guard = Enum.group_by(rows, fn {m, p, _} -> Lens.raw_route_guard(m, p, router) end)

for {g, rs} <- Enum.sort_by(by_guard, fn {g, _} -> to_string(g) end) do
  IO.puts("\n== guard: #{inspect(g)}  (#{length(rs)} rows)  tier=#{inspect(Lens.guard_tier()[g])}")

  for {m, p, t} <- Enum.sort(rs) do
    IO.puts("   #{String.pad_trailing(m, 7)} #{String.pad_trailing(p, 52)} doc=#{t}")
  end
end
