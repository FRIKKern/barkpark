defmodule Barkpark.Config.RuntimePersonalChatApplicationsTest do
  use ExUnit.Case, async: false
  alias Barkpark.StudioChat.ApplicationBinding

  @env "BARKPARK_PERSONAL_CHAT_APPLICATIONS"
  @workspace "11111111-1111-4111-8111-111111111111"
  @host "22222222-2222-4222-8222-222222222222"
  @prod_env %{
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/ignored",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PREVIEW_JWT_SECRET" => String.duplicate("p", 32),
    "BARKPARK_CLOAK_KEY" => Base.encode64(String.duplicate("c", 32)),
    "BARKPARK_KEK" => Base.encode64(String.duplicate("k", 32)),
    "PHX_HOST" => "fixture.invalid"
  }

  setup do
    keys = Map.keys(@prod_env) ++ [@env, "BARKPARK_PAPER_CANVAS"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    old = Application.get_env(:barkpark, :personal_chat_applications)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      if old,
        do: Application.put_env(:barkpark, :personal_chat_applications, old),
        else: Application.delete_env(:barkpark, :personal_chat_applications)
    end)

    Enum.each(@prod_env, fn {key, value} -> System.put_env(key, value) end)
    System.delete_env(@env)
    :ok
  end

  defp fixture_binding do
    %{
      "workspace_id" => @workspace,
      "host_id" => @host,
      "version" => "1",
      "contract_version" => "fixture-context/1"
    }
  end

  defp runtime do
    Config.Reader.read!(Path.join(File.cwd!(), "config/runtime.exs"), env: :prod)
    |> get_in([:barkpark, :personal_chat_applications])
  end

  test "absent and explicit empty object load disabled in actual production runtime config" do
    assert ApplicationBinding.parse_env(nil) == {:ok, %{}}
    assert runtime() == %{}
    System.put_env(@env, "{}")
    assert runtime() == %{}
  end

  test "actual production loader supplies exact closed binding, wrong workspace and removal refuse" do
    System.put_env(@env, Jason.encode!(%{"fixture" => fixture_binding()}))
    loaded = runtime()

    assert loaded == %{
             "fixture" => %{
               workspace_id: @workspace,
               host_id: @host,
               version: "1",
               contract_version: "fixture-context/1"
             }
           }

    Application.put_env(:barkpark, :personal_chat_applications, loaded)

    assert {:ok,
            %{
              "id" => "fixture",
              "host_id" => @host,
              "version" => "1",
              "contract_version" => "fixture-context/1"
            }} = ApplicationBinding.resolve("fixture", @workspace)

    assert {:error, :application_unavailable} = ApplicationBinding.resolve("fixture", @host)

    System.put_env(
      @env,
      Jason.encode!(%{"fixture" => Map.put(fixture_binding(), "version", "2")})
    )

    Application.put_env(:barkpark, :personal_chat_applications, runtime())
    assert {:ok, %{"version" => "2"}} = ApplicationBinding.resolve("fixture", @workspace)
    System.delete_env(@env)
    Application.put_env(:barkpark, :personal_chat_applications, runtime())
    assert {:error, :application_unavailable} = ApplicationBinding.resolve("fixture", @workspace)
  end

  test "strict parser refuses malformed, unknown, partial, credential and noncanonical fields" do
    for raw <- [
          "",
          "null",
          "[]",
          "not json",
          "true",
          "42",
          Jason.encode!(%{"fixture" => nil}),
          Jason.encode!(%{"fixture" => Map.delete(fixture_binding(), "host_id")}),
          Jason.encode!(%{"fixture" => Map.put(fixture_binding(), "token", "do-not-echo-this")})
        ] do
      assert {:error, :invalid_application_config} = ApplicationBinding.parse_env(raw)
    end

    for {field, value} <- [
          {"workspace_id", "wrong"},
          {"host_id", "wrong"},
          {"workspace_id", String.upcase("abcdefab-abcd-4abc-8abc-abcdefabcdef")},
          {"version", " 1"},
          {"version", ""},
          {"version", "a b"},
          {"contract_version", String.duplicate("x", 101)},
          {"contract_version", %{}},
          {"host_id", 1}
        ] do
      assert {:error, :invalid_application_config} =
               ApplicationBinding.parse_env(
                 Jason.encode!(%{"fixture" => Map.put(fixture_binding(), field, value)})
               )
    end

    for id <- ["", " app", "a/b", "a b", String.duplicate("x", 101)] do
      assert {:error, :invalid_application_config} =
               ApplicationBinding.parse_env(Jason.encode!(%{id => fixture_binding()}))
    end
  end

  test "duplicate root and nested JSON keys are rejected before map conversion" do
    body = Jason.encode!(fixture_binding())

    for raw <- [
          "{\"fixture\":#{body},\"fixture\":#{body}}",
          ~s({"fixture":#{body},"f\\u0069xture":#{body}}),
          String.replace(
            "{\"fixture\":#{body}}",
            "\"version\":\"1\"",
            "\"version\":\"1\",\"version\":\"2\""
          )
        ] do
      assert {:error, :invalid_application_config} = ApplicationBinding.parse_env(raw)
    end
  end

  test "count and byte bounds refuse the entire configuration without partial bindings" do
    assert {:ok, bindings} =
             ApplicationBinding.parse_env(
               Jason.encode!(Map.new(1..16, &{"app-#{&1}", fixture_binding()}))
             )

    assert map_size(bindings) == 16

    assert {:error, :invalid_application_config} =
             ApplicationBinding.parse_env(
               Jason.encode!(Map.new(1..17, &{"app-#{&1}", fixture_binding()}))
             )

    assert {:error, :invalid_application_config} =
             ApplicationBinding.parse_env(String.duplicate(" ", 16_385))

    assert {:error, :invalid_application_config} =
             ApplicationBinding.parse_env(
               Jason.encode!(%{"valid" => fixture_binding(), "invalid" => %{}})
             )
  end

  test "explicit malformed deployment input raises a fixed error without its values" do
    secret = "DO-NOT-ECHO-FICTIONAL-INPUT"
    System.put_env(@env, secret)

    assert_raise ArgumentError, "Invalid BARKPARK_PERSONAL_CHAT_APPLICATIONS configuration", fn ->
      runtime()
    end
  end
end
