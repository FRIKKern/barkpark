# Re-prove RouterTierLens against ANY checkout, in seconds.
#
#     elixir cloud/test/support/tier_lens_harness/run_test.exs <repo-root>
#
# WHY THIS EXISTS. The moduledoc tier census normally runs through the full
# cloud suite: a mix project, compiled deps, and a Postgres sandbox. None of
# that is needed to answer "does the lens still resolve every documented route
# to the guard its body enforces?" — the lens is a source parser and the test
# is pure. This runner compiles the two files directly and runs ExUnit in
# process, so the question is answerable against a checkout with no `deps/`,
# no `_build/`, and no database — including one you cannot build in.
#
# That property is the point. It is what let this check keep reporting while
# its author was blocked from git entirely, and it is why a reviewer holding a
# bare checkout can reproduce a tier claim without standing up the stack.
#
# Exit code is the gate: 0 = every tier-bearing row agrees with its route body.
#
# See also, in this directory:
#   rows.exs   — one line per documented row: declared tier vs resolved guard
#   probe.exs  — the same data grouped BY guard, which is how you spot a whole
#                route family collapsed onto one tier
#
# Kept deliberately dependency-free. If it ever needs `mix`, it has lost the
# property it was written for — fix the dependency, not this file.

root = System.argv() |> Enum.at(0)

unless root && File.dir?(Path.join(root, "cloud")) do
  IO.puts(:stderr, """
  usage: elixir run_test.exs <repo-root>

  <repo-root> must be a barkpark checkout (the directory containing `cloud/`).
  """)

  System.halt(2)
end

lens = Path.join(root, "cloud/test/support/router_tier_lens.ex")
test = Path.join(root, "cloud/test/barkpark_cloud/web/router_moduledoc_table_test.exs")

for path <- [lens, test] do
  unless File.exists?(path) do
    IO.puts(:stderr, "missing: #{path}")
    System.halt(2)
  end
end

ExUnit.start(autorun: false)
Code.compile_file(lens)
Code.require_file(test)
System.at_exit(fn _ -> :ok end)
%{failures: failures} = ExUnit.run()
System.halt(if failures == 0, do: 0, else: 1)
