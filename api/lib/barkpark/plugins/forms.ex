defmodule Barkpark.Plugins.Forms do
  @moduledoc """
  Forms — hosted-site form posts become documents in the site's own dataset
  (task-71082f5541c13b53, N-08 in `/papers/netlify-vercel-next-screen-asks`).

  What this plugin contributes:

    * `register_schemas/1` — two PRIVATE types, `form_submission` and
      `form_endpoint` (`Barkpark.Plugins.Forms.Contract` holds the shapes).
      Private keeps both off the anonymous read API; token and Studio reads
      see them.
    * `pre_write_transforms/0` — `Contract.validate/2` as a `:check`, so every
      write of either type, from any door, meets the contract before a row
      is written.
    * `register_routes/1` — the anonymous `POST …/submissions` on the
      `:public_api` bucket (JSON parsing, `PublicCors`, no auth) plus its
      `OPTIONS` preflight twin. The gates live in
      `Barkpark.Plugins.Forms.Web.SubmissionController`.

  Plugin off (`BARKPARK_PLUGINS` without `forms`) = no route and no schema;
  nothing else in Barkpark names this module.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/forms/plugin.json"

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.Forms.Contract

  @dataset_default "production"

  @impl Barkpark.Plugin
  def default_enabled?, do: false

  @impl Barkpark.Plugin
  def register_schemas(opts) do
    dataset = Keyword.get(opts, :dataset, @dataset_default)
    [submission_schema(dataset), endpoint_schema(dataset)]
  end

  @impl Barkpark.Plugin
  def pre_write_transforms do
    [{:check, Contract, :validate}]
  end

  @submissions_path "/forms/w/:workspace/p/:project/d/:dataset/sites/:site/submissions"

  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    [
      {:post, @submissions_path, Barkpark.Plugins.Forms.Web.SubmissionController, :submit,
       auth: :public_api},
      {:options, @submissions_path, Barkpark.Plugins.Forms.Web.SubmissionController, :submit,
       auth: :public_api}
    ]
  end

  defp submission_schema(dataset) do
    %SchemaDefinition{
      name: Contract.submission_type(),
      title: "Form submissions",
      icon: "inbox",
      visibility: "private",
      dataset: dataset,
      fields: [
        %{"name" => "title", "type" => "string", "title" => "Title"},
        %{"name" => "site", "type" => "string", "title" => "Site", "readOnly" => true},
        %{
          "name" => "state",
          "type" => "select",
          "title" => "State",
          "options" => Contract.states()
        },
        %{
          "name" => "spam",
          "type" => "select",
          "title" => "Spam",
          "options" => Contract.spam_dispositions()
        },
        %{
          "name" => "received_at",
          "type" => "datetime",
          "title" => "Received at",
          "readOnly" => true
        },
        %{"name" => "fields", "type" => "text", "title" => "Fields", "readOnly" => true},
        %{"name" => "source", "type" => "text", "title" => "Source", "readOnly" => true},
        %{
          "name" => "endpoint_id",
          "type" => "string",
          "title" => "Endpoint",
          "readOnly" => true
        }
      ]
    }
  end

  defp endpoint_schema(dataset) do
    %SchemaDefinition{
      name: Contract.endpoint_type(),
      title: "Form endpoints",
      icon: "mailbox",
      visibility: "private",
      dataset: dataset,
      fields: [
        %{"name" => "title", "type" => "string", "title" => "Title"},
        %{"name" => "site", "type" => "string", "title" => "Site"},
        %{"name" => "enabled", "type" => "boolean", "title" => "Accepting submissions"},
        %{
          "name" => "allowed_origins",
          "type" => "array",
          "title" => "Allowed origins",
          "of" => [%{"type" => "string"}]
        },
        %{
          "name" => "fields",
          "type" => "array",
          "title" => "Field names",
          "of" => [%{"type" => "string"}]
        }
      ]
    }
  end
end
