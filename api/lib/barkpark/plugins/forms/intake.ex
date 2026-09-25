defmodule Barkpark.Plugins.Forms.Intake do
  @moduledoc """
  Resolve a public form post to the ONE dataset it may land in, then store it.

  ## The target comes from the URL, the permission from the target

  The public URL names the full scope —
  `/v1/plugins/forms/w/:workspace/p/:project/d/:dataset/sites/:site/submissions`
  — and `resolve_endpoint/4` turns it into a binding only when that exact
  dataset holds an enabled `form_endpoint` document for that site. Every read
  here is scoped to the resolved workspace AND project ids
  (`Content.get_document/4` with both, so `Content.Scope`'s strict arm), and
  `store/3` writes with the same two ids and the same dataset string. There is
  no lookup by site slug across tenants, so there is nothing for another
  workspace to claim: a `form_endpoint` for `my-blog` in workspace B only
  opens workspace B's URL.

  Every miss — unknown workspace, archived workspace, unknown project, no
  endpoint document, a disabled one — is the same `{:error, :not_found}`, so
  the endpoint is not an oracle for which workspaces or projects exist.

  No credential is involved at any step: the binding is a document the
  dataset's own writers (or the control plane's admin relay) put there, and
  the post itself carries none.
  """

  alias Barkpark.Content
  alias Barkpark.Plugins.Forms.Contract
  alias Barkpark.Tenancy

  @dataset_slug ~r/^[a-z0-9][a-z0-9_-]{0,63}$/

  @typedoc "A resolved, enabled endpoint."
  @type binding :: %{
          workspace_id: String.t(),
          project_id: String.t(),
          dataset: String.t(),
          site: String.t(),
          allowed_origins: [String.t()],
          fields: [String.t()]
        }

  @doc "Resolve the URL scope to an enabled endpoint binding, or `{:error, :not_found}`."
  @spec resolve_endpoint(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, binding()} | {:error, :not_found}
  def resolve_endpoint(ws_slug, project_slug, dataset, site)
      when is_binary(ws_slug) and is_binary(project_slug) and is_binary(dataset) and
             is_binary(site) do
    with true <- Regex.match?(@dataset_slug, dataset) and Contract.site_slug?(site),
         %Tenancy.Workspace{} = ws <- Tenancy.get_workspace_by_slug(ws_slug),
         false <- Tenancy.Workspace.archived?(ws),
         %Tenancy.Project{} = project <- Tenancy.get_project(ws_slug, project_slug),
         true <- project.workspace_id == ws.id,
         {:ok, doc} <- fetch_endpoint_doc(site, dataset, ws.id, project.id),
         %{"enabled" => true, "site" => ^site} = content <- doc.content || %{},
         :ok <- Contract.validate(Contract.endpoint_type(), %{"content" => content}) do
      {:ok,
       %{
         workspace_id: ws.id,
         project_id: project.id,
         dataset: dataset,
         site: site,
         allowed_origins: content["allowed_origins"],
         fields: content["fields"]
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve_endpoint(_, _, _, _), do: {:error, :not_found}

  # Published first, then the draft: an endpoint an operator created and never
  # published is still their explicit opt-in (`enabled: true` is the switch).
  defp fetch_endpoint_doc(site, dataset, ws_id, project_id) do
    id = Contract.endpoint_doc_id(site)
    opts = [workspace_id: ws_id, project_id: project_id]

    case Content.get_document(id, Contract.endpoint_type(), dataset, opts) do
      {:ok, doc} -> {:ok, doc}
      _ -> Content.get_document("drafts." <> id, Contract.endpoint_type(), dataset, opts)
    end
  end

  @doc """
  Write one `form_submission` into the binding's workspace, project and
  dataset. The contract check runs again inside the writer
  (`Contract.validate/2` as a pre-write `:check`), before the insert.
  """
  @spec store(binding(), map(), map()) :: {:ok, struct()} | {:error, term()}
  def store(binding, fields, meta) do
    content =
      Contract.new_submission(%{
        site: binding.site,
        fields: fields,
        spam: Map.get(meta, :spam, "clean"),
        spam_reasons: Map.get(meta, :spam_reasons, []),
        source: Map.get(meta, :source, %{})
      })

    Content.create_document(
      Contract.submission_type(),
      %{"title" => "Form submission — #{binding.site}", "content" => content},
      binding.dataset,
      workspace_id: binding.workspace_id,
      project_id: binding.project_id
    )
  end

  # A crude, explainable spam signal: link density. Link-stuffed posts are the
  # common bot shape on contact forms. A hit is STORED as `suspected`, not
  # dropped, so a false positive is recoverable from the inbox.
  @max_links 3

  @doc "Machine spam signals for a clean field map: `{disposition, reasons}`."
  @spec spam_signals(map()) :: {String.t(), [String.t()]}
  def spam_signals(fields) do
    links =
      fields
      |> Map.values()
      |> List.flatten()
      |> Enum.map(&length(Regex.scan(~r{https?://}i, &1)))
      |> Enum.sum()

    if links > @max_links, do: {"suspected", ["links"]}, else: {"clean", []}
  end
end
