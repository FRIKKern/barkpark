defmodule BarkparkWeb.Studio.ReturnTo do
  @moduledoc """
  The `return_to` contract for Studio's genuinely flat, scope-free destinations
  (chat, tmux, styleguide, org-admin — charter `bp-studio-deep-link` D5).

  Those surfaces mount with `scope_prefix = ""` and literally cannot build a
  truthful "back to where I came from" path on their own — so a scoped surface
  linking to one attaches `?return_to=<current canonical path>`, the flat
  LiveView threads that value through its OWN `push_patch`es, and any
  back/exit/disabled-fallback redirect prefers the validated `return_to` over
  the `/studio` session funnel (which rides the workspace-teleporting redirect
  resolver).

  This module is deliberately NOT part of `StudioLive.Paths`: Paths is the
  builder for scoped Studio URLs and is being rewritten in the same wave
  (`sdl-w1-builder`); the `return_to` grammar is a small, independent
  open-redirect guard with its own test surface.

  ## Open-redirect guard

  `valid?/1` accepts ONLY a relative, canonical Studio path of the shape
  `/w/:ws/p/:proj[/d/:ds]/studio[/...]` — the exact grammar the scoped mount
  emits. Absolute URLs (`https://evil.com`), scheme-relative hosts
  (`//evil.com`), any non-Studio local path (`/admin`), and empty/nil are all
  rejected, so a hostile `?return_to=` can never bounce a signed-in admin off
  to another origin.
  """

  # Anchored: leading `/w/<ws>/p/<proj>`, an optional `/d/<ds>`, then `/studio`
  # which must be followed by a `/`, a `?` (query), or end-of-string — so
  # `/studioevil` and `/w/../studiobar` never slip through as a `/studio*`
  # prefix trick.
  @canonical ~r{^/w/[^/]+/p/[^/]+(?:/d/[^/]+)?/studio(?:[/?].*)?$}

  @doc """
  Append `?return_to=<www-form-encoded>` to `path` when `return_to` is a
  non-empty string; otherwise return `path` unchanged.

  Callers pass a value they have already run through `sanitize/1` (or a freshly
  built canonical path), so this only performs the encode + join. The flat
  targets it decorates (`/studio/chat`, `/studio/tmux`, `/studio/styleguide`)
  never carry their own query string, so a bare `?` is always correct.
  """
  def with_return_to(path, return_to)

  def with_return_to(path, return_to)
      when is_binary(path) and is_binary(return_to) and return_to != "" do
    path <> "?return_to=" <> URI.encode_www_form(return_to)
  end

  def with_return_to(path, _return_to), do: path

  @doc """
  True iff `value` is a relative, canonical Studio path safe to redirect to.
  """
  def valid?(value) when is_binary(value),
    do: Regex.match?(@canonical, value) and not dot_segment?(value)

  def valid?(_value), do: false

  # Reject dot-segments (`.` / `..`, including their `%2e` spellings — WHATWG
  # URL parsers decode those before resolving). Without this,
  # `/w/a/p/b/studio/../../../../logout` matches the canonical grammar but the
  # browser normalizes it to an arbitrary same-origin path — the back
  # affordance would lie about where it lands.
  defp dot_segment?(value) do
    value
    |> String.split(["/", "?", "#"])
    |> Enum.any?(fn segment ->
      segment
      |> String.downcase()
      |> String.replace("%2e", ".")
      |> Kernel.in([".", ".."])
    end)
  end

  @doc """
  Return `value` when `valid?/1`, else `nil` — the ingestion filter for a
  `return_to` param arriving from the wire.
  """
  def sanitize(value) do
    if valid?(value), do: value, else: nil
  end
end
