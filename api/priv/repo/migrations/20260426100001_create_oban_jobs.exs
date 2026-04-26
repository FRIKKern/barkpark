defmodule Barkpark.Repo.Migrations.CreateObanJobs do
  use Ecto.Migration

  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down(version: 1)
end
