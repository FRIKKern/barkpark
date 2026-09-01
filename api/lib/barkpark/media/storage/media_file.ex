defmodule Barkpark.Media.Storage.MediaFile do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "media_files" do
    field :filename, :string
    field :original_name, :string
    field :path, :string

    # THE OBJECT ADDRESS (task-8eb6542ece62aff1). `path` is the PUBLISHED
    # REFERENCE — the literal string documents persist as `/media/files/<path>`
    # — while this is where THIS ROW's bytes actually live. They are equal for
    # every uncontested row; they diverge only when another tenant already held
    # the flat path, which is exactly the cross-tenant read substitution.
    # Stamped once by `put_object_key/1` below, never recomputed. Owner:
    # `Barkpark.Media.Storage.ObjectKey`.
    field :object_key, :string

    field :mime_type, :string
    field :size, :integer
    field :dataset, :string, default: "production"

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id

    # W2 additive seam. `:dataset_entity` — the legacy `dataset` STRING field
    # still owns `:dataset` (dual presence). FK column is `dataset_id`.
    belongs_to :dataset_entity, Barkpark.Tenancy.Dataset,
      foreign_key: :dataset_id,
      type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(media_file, attrs) do
    media_file
    |> cast(attrs, [
      :filename,
      :original_name,
      :path,
      :mime_type,
      :size,
      :dataset,
      :workspace_id,
      :project_id,
      :dataset_id
    ])
    |> validate_required([:filename, :original_name, :path])
    |> neutralize_dangerous_mime()
    |> put_object_key()
    # W2 uniqueness flip: blob identity is now (path, dataset_id). The `dataset`
    # STRING constraint is dropped at the DB level; the string stays as a mirror.
    |> unique_constraint([:path, :dataset_id],
      name: :media_files_path_dataset_id_index
    )
    # FK-abort containment: all three tenancy columns are real Postgres FKs
    # (migrations 20260527110100 + 20260527131000, default-derived names
    # media_files_<col>_fkey). Without these, a reference to a vanished row —
    # a workspace/project deleted concurrently mid-upload, or a cross-instance
    # blob push carrying a foreign id — raises Ecto.ConstraintError (500) out
    # of Repo.insert instead of returning {:error, changeset}.
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:dataset_id)
  end

  # THE OBJECT ADDRESS IS DECIDED ONCE, AT INSERT (task-8eb6542ece62aff1).
  #
  # `object_key` is deliberately NOT in the `cast/3` list: no caller may name
  # the object another row's bytes live in. It is derived server-side from the
  # row's own `(path, dataset_id)` by `ObjectKey.derive/3`.
  #
  # `prepare_changes/2` rather than a plain step, because the derivation needs a
  # Repo (it asks whether any row already holds this flat path) and must see the
  # row set INSIDE the insert's own transaction. Insert-only: `path` is a
  # published reference and is never updated, so an UPDATE keeps whatever
  # address the row was born with — re-deriving on update is exactly the
  # set-dependent move the moduledoc of `ObjectKey` rules out.
  defp put_object_key(changeset) do
    prepare_changes(changeset, fn prepared ->
      if prepared.action == :insert and is_nil(get_field(prepared, :object_key)) do
        put_change(
          prepared,
          :object_key,
          Barkpark.Media.Storage.ObjectKey.derive(
            prepared.repo,
            get_field(prepared, :path),
            get_field(prepared, :dataset_id)
          )
        )
      else
        prepared
      end
    end)
  end

  # MIME types the browser will execute (script) if it navigates to the blob on
  # the API/Studio origin. Ingest trusts the client Content-Type / a path-derived
  # MIME.from_path, so an outsider-held write key can store a `.svg`/`.html` and
  # get it served inline with its honest `image/svg+xml`/`text/html` type ⇒
  # stored XSS (default asset visibility is public). We treat the whole family
  # (svg, html/xhtml, xml, JS) as dangerous and neutralize it at BOTH the write
  # (recorded mime_type) and the serve edge (`MediaController.maybe_send_file`).
  @dangerous_mimes ~w(
    image/svg+xml
    text/html
    application/xhtml+xml
    text/xml
    application/xml
    application/javascript
    text/javascript
    application/x-javascript
  )

  @neutralized_mime "application/octet-stream"

  @doc """
  True when `mime` is a browser-executable type (svg/html/xml/js). The base type
  is compared case-insensitively with any `; charset=…` parameter stripped.
  """
  def dangerous_mime?(mime) when is_binary(mime) do
    base_mime(mime) in @dangerous_mimes
  end

  def dangerous_mime?(_), do: false

  @doc """
  Map a MIME onto a safe-to-serve content-type: dangerous types collapse to
  `application/octet-stream` (never executed by a browser); everything else is
  returned unchanged. Used by the serve edge to pin a non-executable type.
  """
  def serve_content_type(mime) when is_binary(mime) do
    if dangerous_mime?(mime), do: @neutralized_mime, else: mime
  end

  def serve_content_type(mime), do: mime

  defp base_mime(mime) do
    mime |> String.split(";") |> List.first() |> String.trim() |> String.downcase()
  end

  # Downgrade a hostile recorded mime_type at write so no code path that reads
  # `file.mime_type` can later serve it as executable. Conservative: only the
  # dangerous family is rewritten; every legit image/pdf/… mime is left intact.
  defp neutralize_dangerous_mime(changeset) do
    case get_change(changeset, :mime_type) do
      nil ->
        changeset

      mime ->
        if dangerous_mime?(mime),
          do: put_change(changeset, :mime_type, @neutralized_mime),
          else: changeset
    end
  end
end
