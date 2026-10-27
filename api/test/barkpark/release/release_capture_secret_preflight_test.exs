defmodule Barkpark.Release.ReleaseCaptureSecretPreflightTest do
  @moduledoc """
  Migration 20260719020100 raises without BARKPARK_RELEASE_CAPTURE_HMAC_SECRET.
  `Barkpark.Release.check_release_capture_secret!/2` names the setting before
  any migration runs, and only on a database that still needs that migration.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Release

  @migration 20_260_719_020_100
  @secret String.duplicate("s", 32)

  test "a usable secret passes without reading the database" do
    assert :ok =
             Release.check_release_capture_secret!(Barkpark.Repo,
               secret: @secret,
               migrated_versions: fn -> flunk("read the database") end
             )
  end

  test "a database that already applied the migration passes without the secret" do
    for secret <- [nil, "", "short"] do
      assert :ok =
               Release.check_release_capture_secret!(Barkpark.Repo,
                 secret: secret,
                 migrated_versions: [20_250_101_000_000, @migration]
               )
    end
  end

  test "a fresh database without the secret stops and names the setting" do
    for {secret, versions} <- [{nil, []}, {"leakcheck-value", []}, {nil, [20_250_101_000_000]}] do
      error =
        assert_raise RuntimeError, fn ->
          Release.check_release_capture_secret!(Barkpark.Repo,
            secret: secret,
            migrated_versions: versions
          )
        end

      assert error.message =~ "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET"
      assert error.message =~ "20260719020100"
      assert error.message =~ "openssl rand -base64 32"
      refute error.message =~ "leakcheck-value"
    end
  end

  test "the migration file it guards still exists" do
    path =
      Path.expand(
        "../../../priv/repo/migrations/20260719020100_complete_cycle_release_gate_materialization.exs",
        __DIR__
      )

    assert File.read!(path) =~ "during migration"
  end
end
