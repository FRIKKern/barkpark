defmodule Barkpark.Plugins.OnixEdit.Export.Header do
  @moduledoc """
  ONIX 3.0 `<Header>` builder.

  Boss decision Q4: SenderName is the placeholder `"barkpark.cloud"` for WI2-WI4.
  WI7 (Bokbasen pre-flight) pins the real identifier (likely a GLN).
  """

  @sender_name "barkpark.cloud"

  @doc """
  Build a `<Header>` element.

  Options:

    * `:dataset` (binary, default `"production"`) — written into `<MessageNote>`
      so receivers can disambiguate which dataset a message came from while we
      still allow non-production exports.
    * `:sent_at` (DateTime, default `DateTime.utc_now/0`) — overridable for tests.
  """
  @spec build(keyword() | map()) :: any()
  def build(opts \\ []) do
    opts = Enum.into(opts, [])
    dataset = Keyword.get(opts, :dataset, "production")
    sent_at = Keyword.get(opts, :sent_at, DateTime.utc_now())

    XmlBuilder.element(:Header, [
      XmlBuilder.element(:Sender, [
        XmlBuilder.element(:SenderName, @sender_name)
      ]),
      XmlBuilder.element(:SentDateTime, DateTime.to_iso8601(sent_at)),
      XmlBuilder.element(:MessageNote, "Barkpark dataset:" <> to_string(dataset))
    ])
  end
end
