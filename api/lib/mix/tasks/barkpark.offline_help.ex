defmodule Mix.Tasks.Barkpark.OfflineHelp do
  @moduledoc """
  Write the manifest bp embeds for offline help to
  `internal/cli/offline_help_manifest.json`.

      mix barkpark.offline_help

  The source is `Barkpark.Plugins.Capabilities.offline_help_manifest/0`.
  `test/barkpark/plugins/offline_help_manifest_test.exs` fails when the
  committed file differs, so run this after changing an `org` command.
  """
  use Mix.Task

  @shortdoc "Write internal/cli/offline_help_manifest.json"

  @path Path.expand("../../../../internal/cli/offline_help_manifest.json", __DIR__)

  @doc false
  def path, do: @path

  @doc false
  def render do
    Jason.encode!(Barkpark.Plugins.Capabilities.offline_help_manifest(), pretty: true) <> "\n"
  end

  @impl true
  def run(_args) do
    Mix.Task.run("compile")
    File.write!(@path, render())
    Mix.shell().info("wrote #{Path.relative_to_cwd(@path)}")
  end
end
