defmodule Barkpark.Plugins.ManifestTest do
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Manifest
  alias Barkpark.Plugins.Manifest.InvalidError

  defp minimal do
    %{
      "plugin_name" => "hello",
      "version" => "0.1.0",
      "description" => "A minimal plugin.",
      "capabilities" => ["routes"]
    }
  end

  defp full do
    %{
      "plugin_name" => "onix-edit",
      "version" => "1.2.3-beta.1",
      "description" => "ONIX 3.0 book metadata editor.",
      "capabilities" => [
        "routes",
        "workers",
        "schemas",
        "settings",
        "node",
        "codelists"
      ],
      "module" => "Barkpark.Plugins.OnixEdit",
      "dependencies" => [
        %{"plugin_name" => "core-codelists", "version_req" => "~> 1.0"}
      ],
      "schemas" => [
        %{"name" => "book", "version" => "1", "file" => "schemas/book.json"}
      ],
      "routes" => ["GET /onix/books"],
      "workers" => [
        %{
          "name" => "publisher",
          "child_spec_module" => "Barkpark.Plugins.OnixEdit.Publisher"
        }
      ],
      "settings_schema" => %{
        "type" => "object",
        "required" => ["api_token"],
        "properties" => %{"api_token" => %{"type" => "string"}}
      },
      "codelists" => [
        %{"issue" => 73, "name" => "thema", "file" => "codelists/thema-73.json"}
      ],
      "node" => %{
        "entrypoint" => "ui/index.tsx",
        "package" => "@barkpark/onix-edit",
        "scripts" => %{"lint" => "eslint .", "typecheck" => "tsc --noEmit"}
      }
    }
  end

  describe "schema/0" do
    test "returns the JSON Schema as a map with expected top-level keys" do
      schema = Manifest.schema()
      assert is_map(schema)
      assert schema["title"] == "Barkpark Plugin Manifest"
      assert "plugin_name" in schema["required"]
      assert "version" in schema["required"]
      assert "description" in schema["required"]
      assert "capabilities" in schema["required"]
      assert schema["additionalProperties"] == false
    end
  end

  describe "validate!/1 (success cases)" do
    test "minimal manifest passes and returns the manifest unchanged" do
      assert minimal() == Manifest.validate!(minimal())
    end

    test "full manifest passes" do
      assert full() == Manifest.validate!(full())
    end

    test "manifest with string codelist issue passes" do
      m =
        Map.put(minimal(), "codelists", [
          %{"issue" => "73", "name" => "thema", "file" => "x.json"}
        ])

      assert m == Manifest.validate!(m)
    end
  end

  describe "validate!/1 (failure cases)" do
    test "missing plugin_name raises with plugin_name in message" do
      err =
        assert_raise InvalidError, fn ->
          minimal() |> Map.delete("plugin_name") |> Manifest.validate!()
        end

      assert err.message =~ "plugin_name"
    end

    test "uppercase plugin_name raises" do
      err =
        assert_raise InvalidError, fn ->
          minimal() |> Map.put("plugin_name", "Hello") |> Manifest.validate!()
        end

      assert err.message =~ ~r/plugin_name|pattern/i
    end

    test "leading-digit plugin_name raises" do
      err =
        assert_raise InvalidError, fn ->
          minimal() |> Map.put("plugin_name", "1hello") |> Manifest.validate!()
        end

      assert err.message =~ ~r/plugin_name|pattern/i
    end

    test "non-semver version raises" do
      err =
        assert_raise InvalidError, fn ->
          minimal() |> Map.put("version", "v1") |> Manifest.validate!()
        end

      assert err.message =~ ~r/version|pattern/i
    end

    test "unknown top-level field raises (additionalProperties false)" do
      assert_raise InvalidError, fn ->
        minimal() |> Map.put("nonsense_field", "x") |> Manifest.validate!()
      end
    end

    test "unknown capability raises" do
      assert_raise InvalidError, fn ->
        minimal()
        |> Map.put("capabilities", ["routes", "evil"])
        |> Manifest.validate!()
      end
    end

    test "bad module name (lowercase) raises" do
      assert_raise InvalidError, fn ->
        minimal() |> Map.put("module", "barkpark.plugins.bad") |> Manifest.validate!()
      end
    end
  end

  describe "validate/1 (non-raising)" do
    test "returns {:ok, manifest} on success" do
      assert {:ok, m} = Manifest.validate(minimal())
      assert m == minimal()
    end

    test "missing plugin_name returns {:error, [_ | _]}" do
      assert {:error, errors} = minimal() |> Map.delete("plugin_name") |> Manifest.validate()

      assert is_list(errors)
      assert length(errors) >= 1
      assert Enum.any?(errors, fn e -> e.message =~ "plugin_name" end)
    end

    test "bad plugin_name returns {:error, _}" do
      assert {:error, _} =
               minimal()
               |> Map.put("plugin_name", "Hello")
               |> Manifest.validate()
    end

    test "bad version returns {:error, _}" do
      assert {:error, _} =
               minimal()
               |> Map.put("version", "not-semver")
               |> Manifest.validate()
    end

    test "additional property returns {:error, _}" do
      assert {:error, _} =
               minimal()
               |> Map.put("zzz", true)
               |> Manifest.validate()
    end

    test "unknown capability returns {:error, _}" do
      assert {:error, _} =
               minimal()
               |> Map.put("capabilities", ["bogus"])
               |> Manifest.validate()
    end
  end

  describe "parse_and_validate!/1" do
    @tmp_dir System.tmp_dir!()

    test "reads, decodes, validates a file" do
      path = Path.join(@tmp_dir, "valid_plugin_#{System.unique_integer([:positive])}.json")
      File.write!(path, Jason.encode!(minimal()))
      on_exit(fn -> File.rm(path) end)

      assert minimal() == Manifest.parse_and_validate!(path)
    end

    test "raises on invalid file" do
      path = Path.join(@tmp_dir, "invalid_plugin_#{System.unique_integer([:positive])}.json")
      bad = Map.delete(minimal(), "plugin_name")
      File.write!(path, Jason.encode!(bad))
      on_exit(fn -> File.rm(path) end)

      assert_raise InvalidError, fn -> Manifest.parse_and_validate!(path) end
    end
  end
end
