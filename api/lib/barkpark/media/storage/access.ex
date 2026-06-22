defmodule Barkpark.Media.Storage.Access do
  @moduledoc """
  Per-asset delivery and edit permissions (WoodWing-style governance plane).
  """

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.SignedUrl
  alias Barkpark.Media.Storage.MediaFile

  @type level :: :view | :preview | :original | :edit_metadata

  @doc "Visibility from asset content — `public`, `token`, or `private`."
  @spec visibility(Document.t() | nil) :: String.t()
  def visibility(nil), do: "public"

  def visibility(%Document{content: content}) when is_map(content) do
    Map.get(content, "bp_visibility") || "public"
  end

  def visibility(_), do: "public"

  @doc "Watermark profile from rights composite: `none`, `draft`, `editorial`."
  @spec watermark_profile(Document.t() | nil) :: String.t()
  def watermark_profile(nil), do: "none"

  def watermark_profile(%Document{content: content}) when is_map(content) do
    content
    |> Map.get("rights", %{})
    |> Map.get("watermarkProfile", "none")
    |> case do
      "" -> "none"
      v -> v
    end
  end

  def watermark_profile(_), do: "none"

  @doc "Whether the request may access media at the given level."
  @spec allowed?(Plug.Conn.t(), %MediaFile{}, Document.t() | nil, level()) :: boolean()
  def allowed?(conn, file, doc, level) do
    vis = visibility(doc)
    auth = authenticated?(conn)
    signed = signed_for?(conn, file)
    perms = permission_set(conn, doc)

    cond do
      level == :edit_metadata ->
        "edit_metadata" in perms

      level == :original ->
        "use_original" in perms and delivery_ok?(vis, auth, signed)

      level in [:view, :preview] ->
        "view" in perms and delivery_ok?(vis, auth, signed)

      true ->
        false
    end
  end

  @doc "WoodWing-style permission list for API responses."
  @spec permissions(Plug.Conn.t(), %MediaFile{}, Document.t() | nil) :: [String.t()]
  def permissions(conn, file, doc) do
    permission_set(conn, doc)
    |> Enum.filter(fn perm ->
      case perm do
        "edit_metadata" -> allowed?(conn, file, doc, :edit_metadata)
        "use_original" -> allowed?(conn, file, doc, :original)
        "view" -> allowed?(conn, file, doc, :view)
        "preview" -> allowed?(conn, file, doc, :preview)
        _ -> true
      end
    end)
  end

  defp permission_set(conn, doc) do
    auth = authenticated?(conn)
    admin = auth && admin?(conn)
    checked_out_by = checked_out_by(doc)
    actor = actor_label(conn)

    base =
      case visibility(doc) do
        "private" when not auth -> []
        _ -> ["view", "preview"]
      end

    base =
      if visibility(doc) in ["public", "token"] or auth do
        base ++ ["use_original"]
      else
        base
      end

    base =
      if auth and (admin or checked_out_by in [nil, ""] or checked_out_by == actor) do
        base ++ ["edit_metadata"]
      else
        base
      end

    if checked_out_by not in [nil, ""] and checked_out_by != actor and not admin do
      base -- ["edit_metadata", "use_original"]
    else
      base
    end
    |> Enum.uniq()
  end

  defp delivery_ok?("public", _auth, _signed), do: true
  defp delivery_ok?("token", auth, signed) when auth or signed, do: true
  defp delivery_ok?("token", _, _), do: false
  defp delivery_ok?("private", auth, _) when auth, do: true
  defp delivery_ok?("private", _, _), do: false
  defp delivery_ok?(_, auth, _) when auth, do: true
  defp delivery_ok?(_, _, _), do: false

  defp signed_for?(conn, %MediaFile{id: id}) do
    path = conn.request_path

    SignedUrl.verify?(id, path, SignedUrl.params_from_conn(conn))
  end

  defp authenticated?(conn) do
    match?(%{assigns: %{api_token: %_{} = _}}, conn)
  end

  defp admin?(conn) do
    token = conn.assigns[:api_token]
    Auth.has_permission?(token, "admin")
  end

  defp actor_label(conn) do
    case conn.assigns[:api_token] do
      %{label: label} when is_binary(label) and label != "" -> label
      _ -> "api"
    end
  end

  defp checked_out_by(nil), do: nil

  defp checked_out_by(%Document{content: content}) when is_map(content) do
    Map.get(content, "checkedOutBy")
  end

  defp checked_out_by(_), do: nil
end
