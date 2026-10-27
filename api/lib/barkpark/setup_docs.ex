defmodule Barkpark.SetupDocs do
  @moduledoc """
  Links from setup errors to their section in the self-host guide.

  Every boot, migrate and operator setup error appends `see/1` for its topic,
  so the operator reads the section that explains the setting. The URLs are
  full literals, one per line, so `node tooling/doc-truth/setup-facts.mjs`
  checks that each file and anchor exists. api/entrypoint.sh cannot call this
  module before the release starts, so it repeats the `:media_dir` URL, and
  test/barkpark/setup_docs_test.exs keeps the two equal.
  """

  @links %{
    settings_file:
      "https://github.com/FRIKKern/barkpark/blob/main/docs/setup/SELF-HOST.md#write-and-check-the-settings-file",
    host_name:
      "https://github.com/FRIKKern/barkpark/blob/main/docs/setup/SELF-HOST.md#decide-the-host-name-and-the-org-slug",
    operator_access:
      "https://github.com/FRIKKern/barkpark/blob/main/docs/setup/SELF-HOST.md#pensum-settings",
    media_dir:
      "https://github.com/FRIKKern/barkpark/blob/main/docs/setup/SELF-HOST.md#path-b-azure-container-apps",
    keys:
      "https://github.com/FRIKKern/barkpark/blob/main/docs/setup/SELF-HOST-OPERATIONS.md#rotate-keys",
    database_tls:
      "https://github.com/FRIKKern/barkpark/blob/main/docs/setup/SELF-HOST-OPERATIONS.md#moving-an-instance",
    oidc:
      "https://github.com/FRIKKern/barkpark/blob/main/docs/setup/ENTRA.md#connect-the-app-to-barkpark"
  }

  @type topic ::
          :settings_file
          | :host_name
          | :operator_access
          | :media_dir
          | :keys
          | :database_tls
          | :oidc

  @doc "Every topic and its URL."
  @spec links() :: %{topic() => String.t()}
  def links, do: @links

  @doc "The guide URL for `topic`."
  @spec url(topic()) :: String.t()
  def url(topic), do: Map.fetch!(@links, topic)

  @doc "The sentence a setup error ends with: `See <url>`."
  @spec see(topic()) :: String.t()
  def see(topic), do: "See " <> url(topic)
end
