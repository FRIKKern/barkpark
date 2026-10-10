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

  # The desk entry: the submissions inbox the anonymous posts land in. Without
  # it the type was unreachable from the desk until a submission existed (the
  # …Rest census lists only populated types). Gated on the schema existing.
  # Endpoints are deliberately NOT listed: Cloud provisions them at the
  # deterministic id `Contract.endpoint_doc_id/1`, and a desk "New document"
  # would mint a random id that `Intake.resolve_endpoint/4` never finds.
  @impl Barkpark.Plugin
  def desk_items(dataset),
    do: desk_items_for(schema_present?(Contract.submission_type(), dataset))

  # A workspace-scoped desk build skips the unscoped presence probe, which
  # asks whether ANY workspace has the submission schema in the dataset. The
  # host gate (`Structure.scope_plugin_nodes/4`) decides the type against the
  # caller's own catalog. Same rule as `Barkpark.Plugins.Tasks`
  # (task-90c3a512181b8537). With no scope this is exactly `desk_items/1`.
  @impl Barkpark.Plugin
  def resolve_desk_items(prev, ctx) do
    items =
      if workspace_scoped?(ctx),
        do: desk_items_for(true),
        else: desk_items(Map.get(ctx, :dataset, "production"))

    prev ++ items
  end

  # Same truthiness test as the host gate (`Keyword.get(opts, :workspace_id)`).
  defp workspace_scoped?(%{scope: scope}) when is_list(scope),
    do: Keyword.get(scope, :workspace_id) not in [nil, false]

  defp workspace_scoped?(_ctx), do: false

  defp desk_items_for(true) do
    [
      %{
        type: :document_list,
        label: "Form submissions",
        doc_type: Contract.submission_type(),
        icon: "inbox"
      }
    ]
  end

  defp desk_items_for(false), do: []

  defp schema_present?(name, dataset) do
    match?({:ok, _}, Barkpark.Content.get_schema(name, dataset))
  rescue
    _ -> false
  catch
    _, _ -> false
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
      # Only the public intake writes a submission (its required fields are
      # the intake's), so Studio offers no "New document" for it.
      desk: %{"authorCreatable" => false},
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
