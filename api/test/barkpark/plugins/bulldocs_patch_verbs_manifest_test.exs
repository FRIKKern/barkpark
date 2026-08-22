defmodule Barkpark.Plugins.BulldocsPatchVerbsManifestTest do
  @moduledoc """
  `bp bulldocs patch` accepts six op verbs and, before this test, named NONE of
  them anywhere a caller could reach: `--help` printed only `{"ops":[…]}`, and
  the capabilities manifest carried no verb string. The CLI is manifest-driven,
  so the help text IS this entry — fixing the manifest fixes both surfaces.

  The verbs are pinned against `Barkpark.Content.Papers.BlockOps`' own dispatch
  rather than a hand-copied list, so a verb added to the server without being
  documented reds here.
  """
  use ExUnit.Case, async: true

  @verbs ~w(append-block insert-after patch-block replace-block remove-block move-block)

  defp patch_entry do
    Barkpark.Plugins.Bulldocs.cli_commands()
    |> Enum.find(&(&1[:id] == "bulldocs.patch"))
  end

  defp file_flag_summary do
    patch_entry()
    |> Map.get(:flags, [])
    |> Enum.find(&(&1[:name] == "file"))
    |> Map.get(:summary)
  end

  test "the manifest entry exists and carries a file flag" do
    assert %{} = patch_entry(), "bulldocs.patch vanished from the capabilities manifest"
    assert is_binary(file_flag_summary())
  end

  test "every accepted op verb is named in the manifest a caller reads" do
    summary = file_flag_summary()

    missing = Enum.reject(@verbs, &String.contains?(summary, &1))

    assert missing == [],
           "these op verbs are accepted by the server but named nowhere a caller can " <>
             "discover them: #{inspect(missing)}. `bp bulldocs patch --help` is rendered " <>
             "from this manifest entry, so an undocumented verb is an undiscoverable one."
  end

  test "the pinned verb list still matches the server's own dispatch" do
    # The authority is BlockOps, not this test. If the server learns a seventh
    # verb, this reds and whoever added it updates the manifest in the same
    # change — which is the whole point of pinning against the source.
    source =
      File.read!("lib/barkpark/content/papers/block_ops.ex")

    dispatched =
      Regex.scan(
        ~r/"(append-block|insert-after|patch-block|replace-block|remove-block|move-block)"/,
        source
      )
      |> Enum.map(&List.last/1)
      |> Enum.uniq()
      |> Enum.sort()

    assert dispatched == Enum.sort(@verbs),
           "BlockOps dispatches #{inspect(dispatched)} but this test pins #{inspect(Enum.sort(@verbs))} — " <>
             "reconcile, and update the manifest summary in the same change."
  end
end
