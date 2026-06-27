defmodule Barkpark.Plugins.Indx.PersistenceTest do
  @moduledoc """
  Covers the P4b Hardening B durable key_map storage. Two load-bearing
  properties:

    * round-trip — save then load returns the same %{dataset, key_map}
    * atomic write — a crash mid-write never leaves a partial file
      (we model the partial blob by hand and assert load/1 rejects it)
    * scope sanitization — exotic scope strings never escape the
      configured dir (no path traversal)
    * load_all is the seam Recovery uses at boot
  """
  use ExUnit.Case, async: false

  alias Barkpark.Plugins.Indx.Persistence

  setup do
    # Isolated temp dir per test → no cross-test pollution.
    dir =
      Path.join(System.tmp_dir!(), "indx-persistence-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    prev = Application.get_env(:barkpark, Persistence, [])
    Application.put_env(:barkpark, Persistence, dir: dir)

    on_exit(fn ->
      Application.put_env(:barkpark, Persistence, prev)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "round-trip: save then load returns the same shape" do
    entry = %{
      dataset: "bp_production_v7",
      key_map: %{42 => "post-one", 99 => "post-two"}
    }

    assert :ok = Persistence.save("production", entry)
    assert {:ok, loaded} = Persistence.load("production")
    assert loaded.dataset == "bp_production_v7"
    assert loaded.key_map == %{42 => "post-one", 99 => "post-two"}
  end

  test "load of an unsaved scope returns :error" do
    assert :error = Persistence.load("never-saved")
  end

  test "atomic write: .tmp never lingers on success", %{dir: dir} do
    Persistence.save("scope-a", %{dataset: "d", key_map: %{}})
    files = File.ls!(dir)
    assert "scope-a.term" in files
    refute Enum.any?(files, &String.ends_with?(&1, ".tmp"))
  end

  test "save replaces an existing entry (overwrite-safe)" do
    Persistence.save("scope-b", %{dataset: "old", key_map: %{1 => "a"}})
    Persistence.save("scope-b", %{dataset: "new", key_map: %{2 => "b"}})
    assert {:ok, %{dataset: "new", key_map: %{2 => "b"}}} = Persistence.load("scope-b")
  end

  test "corrupt term file is treated as missing", %{dir: dir} do
    path = Path.join(dir, "scope-c.term")
    File.write!(path, "not a binary term")
    assert :error = Persistence.load("scope-c")
  end

  test "scope with slashes is sanitized; no dir-escape", %{dir: dir} do
    # A scope with a path-traversal-looking string MUST round-trip safely
    # and the file MUST stay inside `dir`.
    weird = "../etc/passwd"
    assert :ok = Persistence.save(weird, %{dataset: "x", key_map: %{}})

    # The file lives inside dir, NOT one level above.
    files = File.ls!(dir)
    assert length(files) == 1

    name = hd(files)
    # The slash is escaped — there is no path component for traversal.
    # A literal ".." in the filename is fine (it's just two dots in a name,
    # not a parent-dir reference, because there's no separator).
    refute String.contains?(name, "/")

    # And load round-trips the exotic scope by sanitizing again.
    assert {:ok, _} = Persistence.load(weird)
  end

  test "load_all returns every saved scope" do
    Persistence.save("a", %{dataset: "da", key_map: %{1 => "x"}})
    Persistence.save("b", %{dataset: "db", key_map: %{2 => "y"}})
    Persistence.save("c", %{dataset: "dc", key_map: %{}})

    all = Persistence.load_all()
    assert map_size(all) == 3
    assert all["a"].dataset == "da"
    assert all["b"].dataset == "db"
    assert all["c"].dataset == "dc"
  end

  test "load_all on a fresh dir returns empty map" do
    # Reset to a clean dir.
    fresh = Path.join(System.tmp_dir!(), "fresh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(fresh)
    on_exit(fn -> File.rm_rf!(fresh) end)

    Application.put_env(:barkpark, Persistence, dir: fresh)

    assert Persistence.load_all() == %{}
  end

  test "path_for is deterministic and inside dir", %{dir: dir} do
    path = Persistence.path_for("hello-world")
    assert path == Path.join(dir, "hello-world.term")
  end
end
