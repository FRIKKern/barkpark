defmodule Mix.Tasks.BarkparkCloud.DuplicateHostnames do
  @moduledoc """
  The prod-duplicate hostname audit (task-b51e13714022da8f): list every hostname
  more than one site or box holds, which teams own the holders, and whether the
  duplicate crosses teams.

  The `add_domain_cross_site_uniqueness` migration froze pre-existing duplicates
  "until the separate prod-duplicate audit resolves them"; this is that audit.
  Its count decides whether a cross-team reclaim remedy is needed at all: zero
  means none, a handful means a one-shot ticket, not a standing route.

  ## Usage

      mix barkpark_cloud.duplicate_hostnames          # human-readable
      mix barkpark_cloud.duplicate_hostnames --json   # one JSON document

  On a release (no Mix):

      bin/barkpark_cloud eval "BarkparkCloud.Registry.duplicate_hostname_census() |> IO.inspect(limit: :infinity)"

  READ-ONLY. It repairs nothing; `Registry.duplicate_hostname_census/0` states
  what it reads and why it does not trust `hostname_claims` for this.
  """
  @shortdoc "List hostnames more than one site/box holds (the prod-duplicate audit)"

  use Mix.Task

  alias BarkparkCloud.Registry

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    rows = Registry.duplicate_hostname_census()

    if "--json" in args do
      Mix.shell().info(Jason.encode!(%{duplicates: rows, count: length(rows)}, pretty: true))
    else
      Mix.shell().info(render(rows))
    end
  end

  @doc false
  @spec render([map()]) :: String.t()
  def render([]), do: "duplicate hostnames: 0 (no hostname is held by more than one site/box)"

  def render(rows) do
    cross = Enum.count(rows, & &1.cross_team)

    header =
      "duplicate hostnames: #{length(rows)} (#{cross} cross-team, #{length(rows) - cross} same-team)"

    body =
      Enum.map(rows, fn row ->
        scope = if row.cross_team, do: "CROSS-TEAM", else: "same team"

        holders =
          Enum.map(row.holders, fn h ->
            "    #{h.kind} #{h.slug} (#{h.id}) team #{h.team_id} via #{h.column}"
          end)

        Enum.join(["  #{row.host} [#{scope}]" | holders], "\n")
      end)

    Enum.join([header | body], "\n")
  end
end
