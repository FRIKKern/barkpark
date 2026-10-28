defmodule Barkpark.Plugins.OfflineHelpManifestTest do
  # bp embeds internal/cli/offline_help_manifest.json so `bp org --help` works
  # with no server. The file must match the command definitions it came from.
  use ExUnit.Case, async: true

  alias Mix.Tasks.Barkpark.OfflineHelp

  test "the committed offline help manifest matches the org commands" do
    committed = File.read!(OfflineHelp.path())

    assert committed == OfflineHelp.render(),
           "internal/cli/offline_help_manifest.json is stale. Run: cd api && mix barkpark.offline_help"
  end

  test "it holds the org noun and the oidc-create command" do
    m = Barkpark.Plugins.Capabilities.offline_help_manifest()

    assert Enum.all?(m["nouns"], &(&1["name"] == "org"))
    assert Enum.any?(m["commands"], &(&1["verb"] == "oidc-create"))
    assert Enum.all?(m["commands"], &(&1["noun"] == "org"))
  end
end
