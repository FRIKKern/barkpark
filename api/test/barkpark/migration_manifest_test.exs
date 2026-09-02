defmodule Barkpark.MigrationManifestTest do
  @moduledoc """
  Tripwire against amending a migration that has already shipped.

  ## The incident

  `20260719010000_add_cycle_correction_quarantine_promotion.exs` shipped in
  `2e0ca88c7a` and was then edited IN PLACE by six later commits
  (`a0357fff38`, `5a7aa8616a`, `223c1264da`, `fbd25ff938`, `d3b7cb1789`,
  `d6c6f94af9`). Its `barkpark_bind_document_revision()` trigger function
  changed shape in the process. Migrations never re-run: every database that
  applied the version before the last edit keeps the OLD object forever, while
  `mix ecto.migrations` reports zero pending — that check reads a row in
  `schema_migrations`, not the object the migration claims to have produced. It
  cost PDS wave 22 an entire wrong root cause (a phantom "OTP 28 divergence").

  ## What this test does

  It hashes every file in `priv/repo/migrations` and compares against the
  committed `MANIFEST.sha256`. Editing a shipped migration's bytes now reds
  HERE, at the edit, naming the file — instead of silently forking the fleet's
  schema for months.

  ## Regenerate (from the repo root) after ADDING a migration

      ( cd api/priv/repo/migrations && shasum -a 256 *.exs ) > api/priv/repo/migrations/MANIFEST.sha256

  (`sha256sum` emits the identical `<hash>  <name>` format, if that is what you
  have.) Regenerating is the right response to a NEW file. It is NOT the right
  response to a CHANGED one — see the failure message.
  """

  use ExUnit.Case, async: true

  @migrations_dir Path.expand("../../priv/repo/migrations", __DIR__)
  @manifest Path.join(@migrations_dir, "MANIFEST.sha256")

  @regen "Regenerate (repo root): ( cd api/priv/repo/migrations && shasum -a 256 *.exs ) > api/priv/repo/migrations/MANIFEST.sha256"

  test "no shipped migration has been edited in place" do
    recorded = read_manifest()
    actual = hash_migrations()

    changed =
      for {name, hash} <- recorded, Map.has_key?(actual, name), actual[name] != hash, do: name

    assert changed == [],
           """
           a shipped migration was edited in place — add a forward migration instead

           Changed: #{Enum.join(changed, ", ")}

           A migration already applied on some database will NEVER re-run there.
           Editing its bytes changes only what FUTURE databases get, and leaves
           every existing one holding the old object with `mix ecto.migrations`
           still reporting clean. Ship the change as a NEW migration that
           CREATE OR REPLACEs / ALTERs the object forward — see
           priv/repo/migrations/20260901140000_replace_bind_document_revision_trigger_function.exs
           for the shape.

           If you are deliberately rewriting history on a migration that has
           provably never left your machine, say so in the PR and then:
           #{@regen}
           """
  end

  test "MANIFEST.sha256 lists exactly the migration files on disk" do
    recorded = read_manifest() |> Map.keys() |> Enum.sort()
    actual = hash_migrations() |> Map.keys() |> Enum.sort()

    assert recorded == actual,
           """
           MANIFEST.sha256 is out of date with priv/repo/migrations.

           Added, not yet recorded: #{inspect(actual -- recorded)}
           Recorded, now missing:   #{inspect(recorded -- actual)}

           Adding a migration is normal — record it: #{@regen}
           A file going MISSING is not: a deleted migration is the same
           permanent-divergence hazard as an amended one, because the databases
           that already ran it keep its effects.
           """
  end

  defp read_manifest do
    @manifest
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [hash, name] = String.split(line, "  ", parts: 2)
      {String.trim(name), hash}
    end)
  end

  defp hash_migrations do
    @migrations_dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Map.new(fn path ->
      digest = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
      {Path.basename(path), digest}
    end)
  end
end
