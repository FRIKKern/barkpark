defmodule Barkpark.Release do
  @moduledoc "Release tasks (run migrations without Mix)."

  @app :barkpark

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          &Ecto.Migrator.run(&1, :up, all: true),
          # `with_repo/3` starts the repo with the SAME config, so a migration
          # connection would otherwise inherit prod's 30 s `statement_timeout`
          # (config/runtime.exs) — and a backfill or a `CREATE INDEX
          # CONCURRENTLY` that Postgres CANCELS at 30 s leaves an INVALID index
          # behind. A migration is an operator-supervised, offline-shaped step:
          # its bound is the deploy window, not a request budget. These opts are
          # passed through to `repo.start_link/1`, where they REPLACE the
          # `:parameters` from config (nothing else sets that key).
          #
          # NOTE, and it is the load-bearing half: `make deploy` migrates via
          # `mix ecto.migrate` (Makefile), not through this function, so this
          # override does not cover the live path. A long migration must still
          # disable the wall itself — see `Barkpark.Repo`'s @moduledoc for the
          # `repo().checkout` + `SET statement_timeout = 0` shape.
          parameters: [statement_timeout: "0"]
        )
    end
  end

  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          seed_script = priv_path_for(repo, "seeds.exs")

          if File.regular?(seed_script) do
            Code.eval_file(seed_script)
          end
        end)
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(@app)
  end

  defp priv_path_for(repo, filename) do
    app = Keyword.get(repo.config(), :otp_app)
    priv_dir = "#{:code.priv_dir(app)}"
    Path.join([priv_dir, "repo", filename])
  end
end
