# One line per documented tier row: the tier the table DECLARES next to the
# guard the route body actually ENFORCES.
#
#     elixir cloud/test/support/tier_lens_harness/rows.exs \
#       cloud/test/support/router_tier_lens.ex \
#       cloud/lib/barkpark_cloud/web/router.ex
#
# Use it when router_moduledoc_table_test reds and you want the disagreement
# named rather than counted, or when reviewing a diff that moves a guard: run
# it before and after and diff the two outputs. That before/after diff is the
# cheapest proof that a moduledoc-only edit displaced nothing — it reports the
# resolved guard for every row, so a guard that moved shows up as a changed
# line even when the router's own diff looks like prose.
#
# Takes explicit paths (not a repo root) so you can point it at a lens from
# one tree and a router from another — comparing a candidate lens against a
# pristine router is exactly how you tell a lens bug from a router bug.

lens = System.argv() |> Enum.at(0)
router = System.argv() |> Enum.at(1)

unless lens && router && File.exists?(lens) && File.exists?(router) do
  IO.puts(:stderr, "usage: elixir rows.exs <router_tier_lens.ex> <router.ex>")
  System.halt(2)
end

Code.compile_file(lens)
alias BarkparkCloud.RouterTierLens, as: Lens

src = File.read!(router)
[_, block] = Regex.run(~r/@moduledoc\s+"""(.*?)"""/s, src)
row_re = ~r/^\s{4,}(GET|POST|PUT|PATCH|DELETE)\s+(\S+)\s+(\S+)/
tokens = Lens.tier_tokens()

block
|> String.split("\n")
|> Enum.flat_map(fn line ->
  case Regex.run(row_re, line) do
    [_, m, p, t] -> if t in tokens, do: [{m, p, t}], else: []
    _ -> []
  end
end)
|> Enum.sort()
|> Enum.each(fn {m, p, t} ->
  IO.puts("#{m}\t#{p}\tdoc=#{t}\tguard=#{inspect(Lens.raw_route_guard(m, p, router))}")
end)
