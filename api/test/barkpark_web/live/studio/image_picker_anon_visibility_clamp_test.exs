defmodule BarkparkWeb.Studio.ImagePickerAnonVisibilityClampTest do
  @moduledoc """
  task-f71cab067a90a89d — `StudioLive.Handlers.Media.open_image_picker/2`
  called `Media.list_files/2` with no visibility clamp, so the picker
  enumerated every image asset in the dataset regardless of `bp_visibility`.

  CONDITIONAL, not live-in-prod-by-default: the door is reachable only where
  `public_demo_studio` is on (default OFF in prod, ON in dev/test — see
  `BarkparkWeb.LiveScope`'s `:anonymous_default` admission arm). This test
  arms the flag explicitly (matching `StudioAnonLockdownTest`'s pattern) and
  mounts the seeded Default workspace as a genuinely anonymous conn — no
  token, no session — the exact posture the finding describes.

  RED-before: with no clamp, the private asset's path appears in the
  rendered picker alongside the public one. GREEN-after: the anonymous
  picker lists only the public asset; an authenticated member (Access.
  authenticated?/1 true) still sees both — the fix is a no-op for real
  Studio users.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Barkpark.Accounts
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @asset_type "mediaAsset"
  @password "correct-horse-battery"

  setup do
    prev = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, true)
    on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev) end)

    ws = Tenancy.get_default_workspace()
    proj = Tenancy.get_default_project()
    # Media fixture trap (Barkpark shared-DB doctrine): `Media.Delivery.Search`
    # resolves the dataset STRING -> dataset_id once a `Tenancy.Dataset` row
    # exists for the project/slug (Default/production does), and then filters
    # `m.dataset_id == ^dataset_id` with NO string fallback for a media_files
    # row — unlike the asset-doc join, which tolerates a nil dataset_id. A
    # fixture that sets only the `dataset` STRING silently vanishes from the
    # listing (empty result, not a leak) the moment that Dataset row exists.
    # Resolve it explicitly so the fixture rows are found the same way real
    # uploaded rows are.
    {:ok, ds} = Tenancy.get_or_create_dataset(proj, @dataset)

    public_file = create_file!(ws, proj, ds)
    private_file = create_file!(ws, proj, ds)
    link_asset!(private_file, ws, proj, "private")
    # No linked asset doc for `public_file` — `Access.visibility(nil) == "public"`,
    # the same null-tolerant default the clamp must honour (a blob with no
    # `mediaAsset` document is public, not hidden).

    %{ws: ws, proj: proj, public_file: public_file, private_file: private_file}
  end

  defp create_file!(ws, proj, ds) do
    suffix = System.unique_integer([:positive])

    {:ok, file} =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: "picker-clamp-#{suffix}.png",
        original_name: "picker-clamp-#{suffix}.png",
        path: "fixtures/picker-clamp-#{suffix}.png",
        mime_type: "image/png",
        size: 1,
        workspace_id: ws.id,
        project_id: proj && proj.id,
        dataset: @dataset,
        dataset_id: ds.id
      })
      |> Repo.insert()

    file
  end

  defp link_asset!(file, ws, proj, visibility) do
    suffix = System.unique_integer([:positive])

    {:ok, _doc} =
      %Document{}
      |> Document.changeset(%{
        doc_id: "picker-clamp-asset-#{suffix}",
        type: @asset_type,
        dataset: @dataset,
        title: "picker clamp asset #{suffix}",
        status: "draft",
        rev: "r#{suffix}",
        content: %{"mediaFileId" => file.id, "bp_visibility" => visibility},
        workspace_id: ws.id,
        project_id: proj && proj.id
      })
      |> Repo.insert()
  end

  defp desk_url, do: "/w/default/p/default/d/#{@dataset}/studio"

  defp open_picker(view), do: render_click(view, "open-image-picker", %{"field" => "cover"})

  test "anonymous demo visitor's picker excludes a private asset", %{
    conn: conn,
    public_file: public_file,
    private_file: private_file
  } do
    {:ok, view, _html} = live(conn, desk_url())

    html = open_picker(view)

    assert html =~ public_file.path
    refute html =~ private_file.path
  end

  test "an authenticated member's picker still sees both — the clamp is a no-op for real users",
       %{conn: conn, ws: ws, public_file: public_file, private_file: private_file} do
    {:ok, user} =
      Accounts.register_user(%{
        email: "picker-member-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")

    conn =
      conn
      |> post("/login/account", %{"email" => user.email, "password" => @password})
      |> recycle()

    {:ok, view, _html} = live(conn, desk_url())

    html = open_picker(view)

    assert html =~ public_file.path
    assert html =~ private_file.path
  end
end
