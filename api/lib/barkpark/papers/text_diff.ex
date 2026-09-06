defmodule Barkpark.Papers.TextDiff do
  @moduledoc """
  Thin delegating façade over `Barkpark.PortableDoc.TextDiff`.

  The line-diff engine itself moved DOWN into the PortableDoc kernel
  (task-9d06bca37668f76a): `PortableDoc.Render.Components` needs it to build
  `chat-tool-diff` rows, and a kernel module must not alias a feature. The
  algorithm is unchanged — see `Barkpark.PortableDoc.TextDiff` for the
  semantics, the size guard and the escaping contract.

  This name is kept because the papers-side callers already speak it
  (`BarkparkWeb.BulldocsLive`'s open-diff modal, `ChatToolRenderer`,
  `Barkpark.TextDiff`'s rail wrapper, `mix barkpark.chat.gen_golden_toolrows`).
  It adds no behaviour of its own; new callers should use the kernel module
  directly.
  """

  alias Barkpark.PortableDoc.TextDiff

  @doc """
  Line-level LCS diff of two strings. See `Barkpark.PortableDoc.TextDiff.diff_lines/2`.
  """
  @spec diff_lines(String.t() | nil, String.t() | nil) :: [%{op: String.t(), text: String.t()}]
  defdelegate diff_lines(old_text, new_text), to: TextDiff

  @doc """
  Render diff chunks to HTML. See `Barkpark.PortableDoc.TextDiff.format_diff_html/1`.
  """
  @spec format_diff_html([%{op: String.t(), text: String.t()}]) :: String.t()
  defdelegate format_diff_html(chunks), to: TextDiff
end
