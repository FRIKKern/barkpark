defmodule BarkparkWeb.MediaVisibilityCopy do
  @moduledoc """
  ONE source of copy for what an asset's `public` delivery visibility actually
  promises, plus the scope's `:media` share state it depends on.

  ## Why this module exists

  `BarkparkWeb.Plugs.RequireShareScope` (RULED 2026-09-06, task-8627e1a3f974693d)
  admits an anonymous read of a NON-Default tenant's scoped media on ONE
  condition: a `:read` share on the scope for the `:media` surface. Route
  admission never reads `bp_visibility` — that field is a serve-time NARROWING
  applied AFTER admission, never an admission widening.

  So the asset-level `public` label OVER-PROMISES on its own. An asset marked
  `public` inside a scope that is NOT shared is readable by workspace members
  and public-read tokens and by nobody else; a website's bare `<img>` gets 403
  on the scoped route. Operators read `public` as world-readable and file it as
  a tenancy bug.

  Every surface that shows or sets an asset's visibility renders the copy from
  HERE — the Studio media library (`BarkparkWeb.Studio.MediaLive`) and `bp`'s
  asset output (`BarkparkWeb.V1.MediaController.show/2`, behind `bp media get`)
  — so the two can never drift into saying different things about the same
  door.

  THE REMEDY IS THE SHARE, NEVER THE LABEL. Nothing here offers to flip
  `bp_visibility`; `remedy/0` names the one verb and the one Studio action that
  create the `:media` `:read` share (`Barkpark.Sharing.publish_media/1`).
  """

  alias Barkpark.Sharing

  @public_label "Public — within this scope's sharing"

  @public_copy "Public means readable within this scope's sharing, not world-readable. " <>
                 "Anonymous readers (a website's bare <img>) reach this asset only while " <>
                 "the scope carries a :media share; marking an asset public opens no door " <>
                 "on its own."

  @shared_state "shared — this scope carries a :media share, so anonymous reads of its public assets resolve"

  @unshared_state "not shared — this scope carries NO :media share, so anonymous reads get 403 even for a public asset"

  @remedy "Publish this scope's media (Studio media library) / `bp share publish-media <scope>` — it creates the :media :read share. Never flip an asset's visibility to fix this."

  @doc "The `public` option's label, identical on every surface."
  @spec public_label() :: String.t()
  def public_label, do: @public_label

  @doc "What `public` actually promises — the copy the label carries with it."
  @spec public_copy() :: String.t()
  def public_copy, do: @public_copy

  @doc "The one remedy. Names the share, never the visibility field."
  @spec remedy() :: String.t()
  def remedy, do: @remedy

  @doc """
  The scope's `:media` share state, as a sentence an operator can act on.

  `true` / `false` in, prose out — so the Studio banner and the `bp` output
  spell the same state the same way.
  """
  @spec share_state(boolean()) :: String.t()
  def share_state(true), do: @shared_state
  def share_state(false), do: @unshared_state

  @doc """
  The whole `public` visibility option for one scope: the label, the copy, the
  scope, and whether that scope currently carries a `:media` share.

  Any of `ws` / `proj` / `dataset` being missing (nil, or a non-binary) makes
  `media_shared?` fail closed to `false` — an unknown scope is never reported
  as shared.
  """
  @spec public_option(term(), term(), term()) :: map()
  def public_option(ws, proj, dataset) do
    shared? = Sharing.media_shared?(ws, proj, dataset)

    %{
      value: "public",
      label: @public_label,
      copy: @public_copy,
      scope: scope_string(ws, proj, dataset),
      media_shared: shared?,
      media_share_state: share_state(shared?),
      remedy: @remedy
    }
  end

  @spec scope_string(term(), term(), term()) :: String.t() | nil
  defp scope_string(ws, proj, dataset)
       when is_binary(ws) and is_binary(proj) and is_binary(dataset),
       do: "#{ws}/#{proj}/#{dataset}"

  defp scope_string(_ws, _proj, _dataset), do: nil
end
