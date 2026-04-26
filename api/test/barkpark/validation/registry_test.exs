defmodule Barkpark.Validation.RegistryTest do
  # The Validation.Registry is a single named GenServer + ETS table.
  # Tests share state — keep this synchronous.
  use ExUnit.Case, async: false

  alias Barkpark.Validation.Registry

  describe "lifecycle" do
    test "is alive after application boot" do
      assert is_pid(GenServer.whereis(Registry))
    end
  end

  describe "built-in checkers" do
    test "isbn13 resolves to the Isbn13Checksum module" do
      assert {:ok, Barkpark.Validation.Checkers.Isbn13Checksum} = Registry.find("isbn13")
    end

    test "every documented built-in is reachable" do
      for name <- ["isbn13", "gtin14", "iso639", "iso4217", "nonempty"] do
        assert {:ok, mod} = Registry.find(name)
        assert is_atom(mod)
      end
    end

    test "unknown name returns :error" do
      assert :error = Registry.find("does-not-exist-#{System.unique_integer([:positive])}")
    end

    test "all/0 enumerates the table" do
      names = Registry.all() |> Enum.map(& &1.name)
      assert "isbn13" in names
      assert "nonempty" in names
    end
  end

  describe "register/2" do
    test "round-trips a fake checker" do
      defmodule FakeChecker do
        @behaviour Barkpark.Validation.Checker
        @impl true
        def check(_v, _a), do: :ok
      end

      name = "fake-#{System.unique_integer([:positive])}"
      :ok = Registry.register(name, FakeChecker)

      assert {:ok, FakeChecker} = Registry.find(name)
    end
  end

  describe "plugin checker registration via Phase 2 contract" do
    test "checkers/0 from a Plugin module is namespaced as plugin:<name>:<checker>" do
      :ok =
        Barkpark.Plugins.Registry.discover_and_register([
          Path.expand("../../support/fixtures/plugins", __DIR__)
        ])

      :ok = Registry.reload_plugin_checkers()

      # The hello fixture plugin defines no checkers/0 of its own; that's
      # fine — reload_plugin_checkers/0 must not raise on plugins without
      # the optional callback.
      assert {:ok, %{module: Barkpark.Plugins.Hello}} = Barkpark.Plugins.Registry.lookup("hello")

      # Drive the namespace path explicitly with an in-test fake plugin.
      defmodule FakePluginCheckerMod do
        @behaviour Barkpark.Validation.Checker
        @impl true
        def check("magic", _), do: :ok
        def check(_, _), do: {:error, :nope}
      end

      defmodule FakePluginMod do
        def checkers, do: [{"magic", FakePluginCheckerMod}]
      end

      :ok = Barkpark.Plugins.Registry.register(FakePluginMod, %{"plugin_name" => "fakeplug"})
      :ok = Registry.reload_plugin_checkers()

      assert {:ok, FakePluginCheckerMod} = Registry.find("plugin:fakeplug:magic")
    end

    test "reload_plugin_checkers/0 is idempotent" do
      :ok = Registry.reload_plugin_checkers()
      :ok = Registry.reload_plugin_checkers()
    end
  end

  describe "individual checkers' check/2 contract" do
    test "isbn13 valid + invalid" do
      m = Barkpark.Validation.Checkers.Isbn13Checksum
      assert :ok = m.check("9780306406157", nil)
      assert {:error, :bad_checksum} = m.check("9780306406158", nil)
      assert {:error, :bad_length} = m.check("123", nil)
      assert {:error, :non_digit} = m.check("9780306abcdef", nil)
      assert {:error, :not_a_string} = m.check(12_345, nil)
    end

    test "gtin14 valid + invalid" do
      m = Barkpark.Validation.Checkers.Gtin14Checksum
      # Hand-checksummed: data digits 1,0,6,1,4,1,4,1,0,0,4,1,5 with weights
      # 3,1,3,1,3,1,3,1,3,1,3,1,3 → sum 76; check digit = (10 − 76 mod 10) mod 10 = 4.
      assert :ok = m.check("10614141004154", nil)
      assert {:error, :bad_checksum} = m.check("10614141004151", nil)
      assert {:error, :bad_length} = m.check("123", nil)
      assert {:error, :non_digit} = m.check("1061414100415X", nil)
    end

    test "iso639 accepts known + rejects unknown" do
      m = Barkpark.Validation.Checkers.Iso639Language
      assert :ok = m.check("eng", nil)
      assert :ok = m.check("EN", nil)
      assert {:error, :unknown_language} = m.check("xqz", nil)
    end

    test "iso4217 accepts known + rejects unknown" do
      m = Barkpark.Validation.Checkers.Iso4217Currency
      assert :ok = m.check("USD", nil)
      assert :ok = m.check("nok", nil)
      assert {:error, :unknown_currency} = m.check("XYZ", nil)
    end

    test "nonempty" do
      m = Barkpark.Validation.Checkers.Nonempty
      assert :ok = m.check("x", nil)
      assert {:error, :empty} = m.check(nil, nil)
      assert {:error, :empty} = m.check("", nil)
      assert {:error, :empty} = m.check([], nil)
      assert {:error, :empty} = m.check(%{}, nil)
    end
  end
end
