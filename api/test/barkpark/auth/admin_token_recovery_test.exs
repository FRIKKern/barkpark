defmodule Barkpark.Auth.AdminTokenRecoveryTest do
  @moduledoc """
  `start.sh admin-token` / `/app/bin/admin-token`: the server-side admin token
  recovery mint (`Barkpark.Auth.AdminTokenRecovery`).
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Barkpark.{Auth, Release, Repo, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Auth.AdminTokenRecovery
  alias Barkpark.TenancyFixtures

  setup do
    dir = Path.join(System.tmp_dir!(), "admin-token-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, token_file: Path.join([dir, "etc", "admin-token"])}
  end

  test "mints an admin token in the default workspace to a 0600 file", %{token_file: file} do
    assert {:ok, r} = AdminTokenRecovery.mint(label: "admin (recovered)", file: file)

    raw = file |> File.read!() |> String.trim()
    assert "bp_admin_" <> _ = raw
    assert File.read!(file <> ".id") == r.id <> "\n"
    assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(file <> ".id").mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(Path.dirname(file)).mode |> Bitwise.band(0o777) == 0o700

    assert {:ok, token} = Auth.verify_token(raw)
    assert token.id == r.id
    assert token.label == "admin (recovered)"
    assert Enum.sort(token.permissions) == ["admin", "read", "write"]
    assert token.workspace_id == Tenancy.get_default_workspace().id
    assert r.workspace_id == token.workspace_id
  end

  test "records an audit row naming a server-side recovery mint", %{token_file: file} do
    {:ok, r} = AdminTokenRecovery.mint(label: "admin (recovered)", file: file)

    event =
      Repo.one!(
        from e in Event, where: e.action == "admin_token_recovery_mint" and e.subject == ^r.id
      )

    assert event.category == "token"
    assert event.actor_type == "system"
    assert event.workspace_id == r.workspace_id
    assert event.metadata["via"] =~ "server-side recovery"
    assert event.metadata["file"] == file
    refute inspect(event.metadata) =~ "bp_admin_"
  end

  test "refuses an existing file without --force and keeps it", %{token_file: file} do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "old\n")
    before = Repo.aggregate(Barkpark.Auth.ApiToken, :count)

    assert {:error, {:file_exists, ^file}} = AdminTokenRecovery.mint(label: "x", file: file)
    assert File.read!(file) == "old\n"
    assert Repo.aggregate(Barkpark.Auth.ApiToken, :count) == before

    assert {:ok, r} = AdminTokenRecovery.mint(label: "x", file: file, force: true)
    refute File.read!(file) == "old\n"
    assert File.read!(file <> ".id") == r.id <> "\n"
  end

  test "requires a label and a default workspace", %{token_file: file} do
    assert {:error, :missing_label} = AdminTokenRecovery.mint(label: "  ", file: file)
    refute File.exists?(file)

    TenancyFixtures.vacate_default_seat!()
    assert {:error, :no_default_workspace} = AdminTokenRecovery.mint(label: "x", file: file)
    refute File.exists?(file)
  end

  test "an unwritable directory mints nothing", %{dir: dir} do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod(dir, 0o700) end)

    # Root ignores the mode bits; there the directory stays writable and the
    # case cannot be built.
    probe = Path.join(dir, "probe")

    case File.write(probe, "") do
      :ok -> File.rm!(probe)
      {:error, _} -> refute_unwritable_mint(dir)
    end
  end

  defp refute_unwritable_mint(dir) do
    before = Repo.aggregate(Barkpark.Auth.ApiToken, :count)

    assert {:error, {:write_failed, _, _}} =
             AdminTokenRecovery.mint(label: "x", file: Path.join(dir, "admin-token"))

    assert Repo.aggregate(Barkpark.Auth.ApiToken, :count) == before
  end

  test "the CLI prints the id and the path, never the token", %{token_file: file} do
    out =
      capture_io(fn ->
        assert AdminTokenRecovery.cli(["--label", "admin (recovered)", "--file", file]) == 0
      end)

    raw = file |> File.read!() |> String.trim()
    id = file |> Kernel.<>(".id") |> File.read!() |> String.trim()
    assert out =~ "Admin token id: #{id}"
    assert out =~ file
    refute out =~ raw

    err =
      capture_io(:stderr, fn ->
        assert AdminTokenRecovery.cli(["--label", "again", "--file", file]) == 1
      end)

    assert err =~ "already exists"
    assert err =~ "--force"

    assert capture_io(:stderr, fn -> assert AdminTokenRecovery.cli(["--bogus"]) == 2 end) =~
             "usage"
  end

  test "the release entry reads its arguments from BARKPARK_ADMIN_TOKEN_ARGV", %{token_file: file} do
    System.put_env("BARKPARK_ADMIN_TOKEN_ARGV", "--label\nadmin (container)\n--file\n#{file}\n")
    on_exit(fn -> System.delete_env("BARKPARK_ADMIN_TOKEN_ARGV") end)

    capture_io(fn ->
      Release.admin_token(boot: fn -> :ok end, halt: &send(self(), {:halt, &1}))
    end)

    assert_received {:halt, 0}
    {:ok, token} = file |> File.read!() |> String.trim() |> Auth.verify_token()
    assert token.label == "admin (container)"
  end

  test "start.sh and the release overlay both expose the command" do
    start = File.read!(Path.expand("../../../start.sh", __DIR__))
    assert start =~ "admin-token)"
    assert start =~ "exec mix barkpark.admin_token \"$@\""

    overlay = Path.expand("../../../rel/overlays/bin/admin-token", __DIR__)
    assert File.read!(overlay) =~ ~s|eval "Barkpark.Release.admin_token()"|
    assert Bitwise.band(File.stat!(overlay).mode, 0o111) != 0
  end
end
