defmodule Barkpark.Plugins.OnixEdit.PluginSettings do
  @moduledoc """
  Declarative settings form for the admin Plugin Settings LiveView.

  Field names are dot-namespaced: the leading segment is the `plugin_settings`
  row the value lands in (`"bokbasen"` here), and the remainder is the flat
  key inside that row. This is the exact shape
  `Barkpark.Plugins.OnixEdit.Bokbasen.Settings.get_credentials/0` reads
  back — the LiveView does not invent a new storage layout, it mirrors
  what the runtime client already expects.

  Extracted verbatim from `Barkpark.Plugins.OnixEdit.settings_schema/0`
  behind the plugin facade — the callback delegates here. The returned
  shape is byte-identical to before.
  """

  @doc """
  The settings field list. Returned unchanged from the former
  `OnixEdit.settings_schema/0` body.
  """
  @spec schema() :: [map()]
  def schema do
    [
      %{
        name: "bokbasen.api_base",
        type: :url,
        label: "Bokbasen API base URL",
        required: true,
        default: "https://api.bokbasen.io",
        placeholder: "https://api.bokbasen.io",
        group: "Bokbasen",
        hint: "Production: https://api.bokbasen.io  ·  Sandbox: https://api-sandbox.bokbasen.io"
      },
      %{
        name: "bokbasen.oauth_token_url",
        type: :url,
        label: "OAuth token URL",
        required: true,
        default: "https://login.bokbasen.io/oauth2/token",
        placeholder: "https://login.bokbasen.io/oauth2/token",
        group: "Bokbasen"
      },
      %{
        name: "bokbasen.client_id",
        type: :string,
        label: "Client ID",
        required: true,
        masked: true,
        group: "Bokbasen"
      },
      %{
        name: "bokbasen.client_secret",
        type: :password,
        label: "Client secret",
        required: true,
        masked: true,
        group: "Bokbasen",
        hint: "Stored encrypted at rest via BARKPARK_CLOAK_KEY"
      },
      %{
        name: "bokbasen.client_role",
        type: :select,
        label: "Client role",
        required: true,
        options: ["publisher", "distributor"],
        default: "publisher",
        group: "Bokbasen"
      }
    ]
  end
end
