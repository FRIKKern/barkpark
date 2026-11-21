defmodule Barkpark.Plugins.CapabilitiesTokenCreateHelpTest do
  @moduledoc """
  The `token.create` help is what agents read before they mint. It said
  "read-only" and "public-read|read ONLY" while `bp token create --permissions
  read,write` already minted write tokens through `/v1/tokens/elevated`
  (`internal/cli/token_create_cmd.go`). Agents concluded that write tokens could
  not be made here and used `app_token create`, which seated the token in the
  wrong workspace (task-d0408c73a9206555).

  This pins what the help must say: every permission bp accepts, the elevated
  route and its admin requirement, and one example that binds a dataset.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Capabilities

  defp token_create do
    Capabilities.manifest("admin", project: false)["commands"]
    |> Enum.find(&(&1["id"] == "token.create"))
  end

  test "the summary names every permission and the elevated route" do
    summary = token_create()["summary"]

    for word <- ["public-read", "read", "write", "admin", "/v1/tokens/elevated", "admin seat"] do
      assert summary =~ word, "summary does not name #{inspect(word)}: #{summary}"
    end

    refute summary =~ "read-only"
  end

  test "--permissions names write and admin, their requirement, and binds a dataset in its example" do
    help =
      token_create()["flags"]
      |> Enum.find(&(&1["name"] == "permissions"))
      |> Map.fetch!("summary")

    for word <- ["write", "admin", "/v1/tokens/elevated", "admin seat"] do
      assert help =~ word, "--permissions help does not name #{inspect(word)}: #{help}"
    end

    refute help =~ "ONLY"
    assert help =~ ~r/Example: bp .*token create .*--permissions read,write .*--dataset \S+/
  end
end
