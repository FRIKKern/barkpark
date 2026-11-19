defmodule BarkparkWeb.Studio.ImageRefUrl do
  @moduledoc """
  The URL of an image stored in the reference shape, `{asset: {_ref:
  "image-<sha1>-<w>x<h>-<ext>"}}`, for the readers that show a document's
  image (`Barkpark.Content.PreviewText`'s `:image_ref`): the list rows of
  the desk and the old Studio, and search's `_preview.media`.

  The value carries no `url`, so it is the Sanity-compatible route of the
  reader's own dataset and scope, `<scope>/images/barkpark/<dataset>/<sha1>-
  <w>x<h>.<ext>` (`MediaController.serve_sanity_image`, the same URL the
  picker and the array field draw: `FieldInputs.sanity_image_url/4`). The
  route exists only under `/w/:ws/p/:proj`, so with no scope there is no URL.
  """

  alias Barkpark.Content.PreviewText
  alias Barkpark.Tenancy
  alias BarkparkWeb.Components.FieldInputs
  alias BarkparkWeb.Studio.StudioLive.Paths

  # A list row's thumbnail and a search hit's media are small.
  @width 120

  @doc """
  The resolver for `dataset` under `prefix` (`/w/:ws/p/:proj`), or nil with
  no prefix.
  """
  @spec resolver(String.t(), String.t() | nil) :: (String.t() -> String.t() | nil) | nil
  def resolver(_dataset, prefix) when prefix in [nil, ""], do: nil

  def resolver(dataset, prefix) when is_binary(dataset),
    do: &FieldInputs.sanity_image_url(&1, prefix, dataset, @width)

  def resolver(_dataset, _prefix), do: nil

  @doc """
  The `/w/:ws/p/:proj` prefix: `prefix` when given, else the one the scope's
  workspace and project ids name, else `""`.
  """
  @spec prefix(String.t() | nil, keyword() | nil) :: String.t()
  def prefix("/" <> _ = prefix, _scope), do: prefix

  def prefix(_prefix, scope) when is_list(scope) do
    with %{slug: ws} <- Tenancy.get_workspace_by_id(scope[:workspace_id]),
         %{slug: proj, workspace_id: ws_id} <- Tenancy.get_project_by_id(scope[:project_id]),
         true <- ws_id == scope[:workspace_id] do
      Paths.scope_prefix(ws, proj)
    else
      _ -> ""
    end
  end

  def prefix(_prefix, _scope), do: ""

  @doc """
  A list's media pick for its `list_preview.media` `spec`: `{declared?,
  fun}`, where `fun.(root, deref)` is `PreviewText.media_item/4` with this
  list's resolver (`for_rows/2`, read once), or `{false, nil}` when the spec
  names no media.
  """
  @spec media(term(), String.t(), keyword()) :: {boolean(), (map(), term() -> term()) | nil}
  def media(spec, dataset, opts) do
    if PreviewText.media?(spec) do
      image = [image_ref: for_rows(dataset, opts)]
      {true, &PreviewText.media_item(spec, &1, &2, image)}
    else
      {false, nil}
    end
  end

  @doc "The resolver for a list build's `opts` (`:scope_prefix`, `:scope`)."
  @spec for_rows(String.t(), keyword()) :: (String.t() -> String.t() | nil) | nil
  def for_rows(dataset, opts),
    do: resolver(dataset, prefix(Keyword.get(opts, :scope_prefix), Keyword.get(opts, :scope)))
end
