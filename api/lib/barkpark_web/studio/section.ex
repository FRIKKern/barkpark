defmodule BarkparkWeb.Studio.Section do
  @moduledoc """
  Which Studio section a viewer is on, DERIVED from `current_path`.

  `current_path` has one producer (`BarkparkWeb.StudioChrome`'s
  `handle_params` hook) and is already the oracle for tab active-state
  (`StudioComponents.Nav.plugin_tab_active?/2`). This module closes the
  last mile: the two remaining chrome decisions that used to read a
  hand-assigned `:nav_section` atom — the DatasetSwitcher's navigation
  suffix and the api-tester top-bar action group — now ask the path.

  A hand-assign could disagree with the URL (a `push_patch` moves the
  path and leaves the mount-time atom frozen); a derivation cannot.

  ## Shape

  Both canonical Studio URL shapes put the section AFTER the last
  `studio` segment:

      /studio/:dataset[/:section...]                  (flat)
      /w/:ws/p/:proj/d/:dataset/studio[/:section...]  (scoped)

  The flat shape interposes the dataset, and a dataset may legally be
  NAMED `media` — `/studio/media` is that dataset's STRUCTURE page, not
  the media surface — so the dataset segment is dropped by identity
  against the known dataset rather than by position alone.

  Anything that is not `media` or `api-tester` (a plugin surface such as
  `/studio/tickets`, the flat `chat`/`tmux` singletons, an unparseable or
  nil path) answers `:structure`, whose suffix is `""` — the same answer
  the retired `section_suffix/1` gave through its catch-all clause and
  the `|| :structure` default at the layout call site.
  """

  @type t :: :structure | :media | :api_tester

  @doc "The section `current_path` is on. Never raises; defaults to `:structure`."
  @spec from_path(String.t() | nil, String.t() | nil) :: t()
  def from_path(current_path, dataset \\ nil)

  def from_path(current_path, dataset) when is_binary(current_path) do
    current_path
    |> String.split("/", trim: true)
    |> Enum.map(&URI.decode/1)
    |> after_studio()
    |> drop_dataset(dataset)
    |> classify()
  end

  def from_path(_current_path, _dataset), do: :structure

  @doc """
  The raw path suffix a dataset switch must preserve, derived from
  `current_path`. `""` / `"/media"` / `"/api-tester"`.
  """
  @spec suffix(String.t() | nil, String.t() | nil) :: String.t()
  def suffix(current_path, dataset \\ nil),
    do: current_path |> from_path(dataset) |> suffix_for()

  defp suffix_for(:media), do: "/media"
  defp suffix_for(:api_tester), do: "/api-tester"
  defp suffix_for(_), do: ""

  defp after_studio(segments) do
    case Enum.find_index(Enum.reverse(segments), &(&1 == "studio")) do
      nil -> []
      index -> Enum.drop(segments, length(segments) - index)
    end
  end

  defp drop_dataset([dataset | rest], dataset) when is_binary(dataset), do: rest
  defp drop_dataset(segments, _dataset), do: segments

  defp classify(["media" | _]), do: :media
  defp classify(["api-tester" | _]), do: :api_tester
  defp classify(_), do: :structure
end
