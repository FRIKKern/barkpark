defmodule Barkpark.Plugins.OnixEdit.ApiTestsTest do
  @moduledoc """
  Shape-validation tests for `Barkpark.Plugins.OnixEdit.api_tests/0`
  (Goal `barkpark-bsp`).

  The plugin ships four declarative smoke specs (legacy `/api/schemas`,
  admin `/v1/schemas/production`, the `/studio/production` chrome
  render, and a mutation round-trip with `:cleanup`). We do NOT fire
  the specs here — that is the runner integration's job. Instead this
  file pins the *contract* of the spec list:

    * Exactly 4 specs.
    * Each spec has `:name`, `:method`, `:path`, `:asserts`.
    * Methods are atoms in the allowed set.
    * Paths begin with `/`.
    * Auth modes match the documented set (`:none | :admin | {:token,
      String.t} | {:plugin_setting, String.t}`).
    * The mutation spec carries `:cleanup`; every other spec does not.
    * The mutation spec's body parses as a JSON-able map (no atoms in
      the keys — string-keyed all the way down, so `Jason.encode/1`
      cannot trip on atom collisions).

  Pure shape — no Registry, no Req. Safe `async: true`.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Plugins.OnixEdit

  @allowed_methods [:get, :post, :put, :patch, :delete]

  setup_all do
    specs = OnixEdit.api_tests()
    {:ok, specs: specs}
  end

  describe "OnixEdit.api_tests/0 — list shape" do
    test "returns exactly 4 specs", %{specs: specs} do
      assert length(specs) == 4
    end

    test "every spec is a map", %{specs: specs} do
      assert Enum.all?(specs, &is_map/1)
    end
  end

  describe "OnixEdit.api_tests/0 — per-spec required keys" do
    test "every spec has :name, :method, :path, :asserts", %{specs: specs} do
      for spec <- specs do
        assert Map.has_key?(spec, :name), "missing :name on #{inspect(spec)}"
        assert Map.has_key?(spec, :method), "missing :method on #{inspect(spec)}"
        assert Map.has_key?(spec, :path), "missing :path on #{inspect(spec)}"
        assert Map.has_key?(spec, :asserts), "missing :asserts on #{inspect(spec)}"
      end
    end

    test "every :name is a non-empty string", %{specs: specs} do
      for spec <- specs do
        assert is_binary(spec.name)
        assert spec.name != ""
      end
    end

    test "every :method is one of #{inspect(@allowed_methods)}", %{specs: specs} do
      for spec <- specs do
        assert spec.method in @allowed_methods,
               "method #{inspect(spec.method)} not in allowed set for #{spec.name}"
      end
    end

    test "every :path is a binary that starts with '/'", %{specs: specs} do
      for spec <- specs do
        assert is_binary(spec.path), "path is not a binary on #{spec.name}"

        assert String.starts_with?(spec.path, "/"),
               "path #{inspect(spec.path)} on #{spec.name} does not start with '/'"
      end
    end

    test "every :asserts is a non-empty list", %{specs: specs} do
      for spec <- specs do
        assert is_list(spec.asserts)
        assert length(spec.asserts) > 0, "empty :asserts on #{spec.name}"
      end
    end

    test "every :auth is one of the documented modes when present", %{specs: specs} do
      for spec <- specs do
        case Map.get(spec, :auth, :none) do
          :none -> :ok
          :admin -> :ok
          {:token, t} -> assert is_binary(t)
          {:plugin_setting, k} -> assert is_binary(k)
          other -> flake_invalid_auth(spec.name, other)
        end
      end
    end

    defp flake_invalid_auth(name, other) do
      flunk("Spec #{name} has invalid :auth value #{inspect(other)}")
    end
  end

  describe "OnixEdit.api_tests/0 — public reads" do
    test "the /api/schemas spec is a no-auth GET", %{specs: specs} do
      [spec] = Enum.filter(specs, &(&1.path == "/api/schemas"))
      assert spec.method == :get
      assert spec.auth == :none
    end

    test "the /v1/schemas/production spec is an admin GET", %{specs: specs} do
      [spec] = Enum.filter(specs, &(&1.path == "/v1/schemas/production"))
      assert spec.method == :get
      assert spec.auth == :admin
    end

    test "the /studio/production spec is a no-auth GET", %{specs: specs} do
      [spec] = Enum.filter(specs, &(&1.path == "/studio/production"))
      assert spec.method == :get
      assert spec.auth == :none
    end
  end

  describe "OnixEdit.api_tests/0 — mutation spec" do
    test "the mutation POST spec has :cleanup with at least one step", %{specs: specs} do
      [spec] = Enum.filter(specs, &(&1.method == :post))
      assert spec.path == "/v1/data/mutate/production"
      assert spec.auth == :admin
      assert Map.has_key?(spec, :cleanup)
      assert is_list(spec.cleanup)
      assert length(spec.cleanup) >= 1
    end

    test "the mutation spec's :body round-trips through Jason.encode/1", %{specs: specs} do
      [spec] = Enum.filter(specs, &(&1.method == :post))
      assert Map.has_key?(spec, :body)
      assert {:ok, encoded} = Jason.encode(spec.body)
      assert is_binary(encoded)

      # Sanity: decoding back lands a map with a "mutations" list so
      # the runner's :json body step has something coherent to send.
      assert {:ok, decoded} = Jason.decode(encoded)
      assert is_map(decoded)
      assert is_list(decoded["mutations"])
      assert length(decoded["mutations"]) > 0
    end

    test "the mutation spec's :cleanup steps have :method + :path", %{specs: specs} do
      [spec] = Enum.filter(specs, &(&1.method == :post))

      for step <- spec.cleanup do
        assert Map.has_key?(step, :method),
               "cleanup step missing :method on spec #{spec.name}"

        assert Map.has_key?(step, :path),
               "cleanup step missing :path on spec #{spec.name}"

        assert step.method in @allowed_methods
        assert String.starts_with?(step.path, "/")
      end
    end

    test "non-mutation specs do NOT carry :cleanup", %{specs: specs} do
      for spec <- specs, spec.method != :post do
        refute Map.has_key?(spec, :cleanup),
               "GET spec #{spec.name} should not declare :cleanup"
      end
    end
  end
end
