defmodule Barkpark.MixBootTest do
  @moduledoc """
  Guards the one-shot Mix-task boot contract (task-557cf9a71e949768).

  ## Why these assertions read a PLAN and a SOURCE file

  `mix test` starts the whole `:barkpark` application, so `BarkparkWeb.Endpoint`
  and the `Oban` instance are ALREADY alive in this VM. `Process.whereis/1`
  therefore cannot distinguish a task that boots minimally from one that calls
  `Mix.Task.run("app.start")` — both would observe the same live processes, and
  the test would be a green with no subject. The two things that actually decide
  what a one-shot starts on a live box are:

    1. `Barkpark.MixBoot.boot_plan/1` — the ordered child list handed to
       `Supervisor.start_link/2`. If the Endpoint / Oban are not in it, no
       listener and no second queue drainer can exist.
    2. Whether the task's `run/1` calls `Barkpark.MixBoot.boot!/1` at all, or
       still opens with `Mix.Task.run("app.start")`.

  So (1) is asserted against the plan and (2) against the task source. Restoring
  `Mix.Task.run("app.start")` in any converted task reds the source arm.
  """
  use ExUnit.Case, async: true

  alias Barkpark.MixBoot

  @tiers [:repo, :projector, :content_write]

  # The one-shots converted off `app.start`, with the tier each must request.
  @converted %{
    "lib/mix/tasks/barkpark.edges.backfill.ex" => ":projector",
    "lib/mix/tasks/barkpark.media.backfill.ex" => ":content_write",
    "lib/mix/tasks/barkpark.paper.backfill_block_ids.ex" => ":repo",
    "lib/mix/tasks/barkpark.paper.composition_migrate.ex" => ":repo",
    "lib/mix/tasks/barkpark.paper.doctrine_backfill.ex" => ":repo"
  }

  defp child_module({mod, _}), do: mod
  defp child_module(%{start: {mod, _, _}}), do: mod
  defp child_module(mod) when is_atom(mod), do: mod

  defp modules(tier), do: Enum.map(MixBoot.children_for(tier), &child_module/1)

  describe "criterion 0 — repo + task deps only" do
    test "no tier starts the Endpoint, Oban, plugin workers, Indx, sharing or the other app.start tiers" do
      forbidden = MixBoot.forbidden_children()

      # Control: the forbidden list is non-empty and actually names the two the
      # incident cost us, so an empty list can never manufacture a pass.
      assert BarkparkWeb.Endpoint in forbidden
      assert Oban in forbidden

      for tier <- @tiers do
        mods = modules(tier)

        for banned <- forbidden do
          refute banned in mods,
                 "tier #{inspect(tier)} starts #{inspect(banned)}, which a one-shot never needs"
        end

        assert Barkpark.Repo in mods, "tier #{inspect(tier)} must start the Repo"
        refute MixBoot.boot_plan(tier).starts_endpoint?
        refute MixBoot.boot_plan(tier).starts_oban?
      end
    end

    test ":repo is the Repo and nothing but the Repo (plus its Vault)" do
      assert modules(:repo) == [Barkpark.Vault, Barkpark.Repo]
    end

    test ":projector adds the graph deps and :content_write adds schema registration" do
      projector = modules(:projector)
      assert Barkpark.Plugins.Registry in projector
      assert Phoenix.PubSub in projector
      refute Barkpark.SchemaBootstrap in projector

      content_write = modules(:content_write)
      assert Barkpark.SchemaBootstrap in content_write
      # Registry must precede SchemaBootstrap — it registers plugin schemas.
      assert Enum.find_index(content_write, &(&1 == Barkpark.Plugins.Registry)) <
               Enum.find_index(content_write, &(&1 == Barkpark.SchemaBootstrap))
    end

    test "codelist seeders are disabled before SchemaBootstrap can read the flag" do
      # ERROR 57014 query_canceled, guerrilla 2026-09-02: the onixedit codelist
      # seeder ran on a one-shot's boot and hit the 60 s statement_timeout.
      assert Keyword.fetch!(MixBoot.env_overrides(), :run_boot_codelist_seeders) == false
    end

    test "the dependency-app list never contains :barkpark itself" do
      apps = MixBoot.dependency_apps()
      # Control: the list is real, not empty (an empty list would pass the
      # refute below vacuously).
      assert :ecto_sql in apps
      refute :barkpark in apps
    end
  end

  describe "criterion 1 — PHX_SERVER binds no port" do
    test "with PHX_SERVER=true the plan still has no Endpoint child" do
      prior = System.get_env("PHX_SERVER")

      try do
        System.put_env("PHX_SERVER", "true")

        for tier <- @tiers do
          plan = MixBoot.boot_plan(tier)

          refute plan.starts_endpoint?,
                 "PHX_SERVER must not put an Endpoint in the #{inspect(tier)} plan"

          refute BarkparkWeb.Endpoint in Enum.map(plan.children, &child_module/1)
        end
      after
        if prior, do: System.put_env("PHX_SERVER", prior), else: System.delete_env("PHX_SERVER")
      end
    end

    test "config/runtime.exs is the only thing PHX_SERVER reaches, and it only sets server: true" do
      # The runtime config sets `server: true` on the Endpoint. That flag is
      # inert unless something STARTS the Endpoint — and nothing in any tier
      # does (asserted above). This pins the reasoning to the actual source so
      # a future runtime.exs that starts a listener some other way reds here.
      source = File.read!(Path.join(__DIR__, "../../../config/runtime.exs"))
      [_, block] = String.split(source, ~s|if System.get_env("PHX_SERVER") do|, parts: 2)
      [body, _] = String.split(block, "\nend\n", parts: 2)

      assert String.trim(body) ==
               "config :barkpark, BarkparkWeb.Endpoint, server: true"
    end
  end

  describe "the converted one-shots" do
    test "each calls Barkpark.MixBoot.boot!/1 with its tier and no longer calls app.start" do
      for {relpath, tier} <- @converted do
        path = Path.join(__DIR__, "../../../" <> relpath)
        source = File.read!(path)

        refute source =~ ~s|Mix.Task.run("app.start")|,
               "#{relpath} still boots the whole application"

        assert source =~ "Barkpark.MixBoot.boot!(#{tier})",
               "#{relpath} must boot the #{tier} tier"
      end
    end
  end
end
