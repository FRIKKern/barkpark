defmodule Barkpark.Media.Storage.CheckoutTest do
  # PIN TEST — locks the CURRENT force-release contract so a future tightening
  # reds here instead of silently shipping.
  #
  # `Checkout.undo_checkout/4` takes an `admin?` boolean the controller computes
  # as write-OR-admin (`MediaController.admin?/1`), so on the API path any write
  # token force-releases ANY actor's lock — the @doc and the controller intent
  # comment both name this. These tests hold that behavior at the substrate
  # boundary: `admin? == true` releases a non-holder's checkout {:ok};
  # `admin? == false` from a non-holder is refused {:error, :forbidden}. If the
  # posture is ever tightened to true-admin
  # (felix-w28-bl-checkout-tighten-adjudication), the first assertion flips red.
  #
  # A force-release also drops the file's cached renditions
  # (`patch_checkout/5`: actor == nil -> Renditions.delete_for_file) — named
  # here as the documented side effect of the release path.
  use Barkpark.DataCase, async: false

  alias Barkpark.Media.Storage.Checkout
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Repo

  @dataset "production"

  defp insert_file do
    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: "a.png",
      original_name: "a.png",
      path: "2026/05/a.png",
      mime_type: "image/png",
      size: 10,
      dataset: @dataset
    })
    |> Repo.insert!()
  end

  # Establish an asset doc checked out by `holder` (an actor other than the one
  # attempting the release), so the release is always a NON-holder force-release.
  defp file_locked_by(holder) do
    file = insert_file()
    {:ok, _doc} = Assets.ensure_for_upload(file)
    {:ok, _doc} = Checkout.checkout(file, holder, @dataset)
    file
  end

  test "a write-only token (admin? == true) force-releases another actor's checkout" do
    file = file_locked_by("someone-else")

    assert {:ok, doc} = Checkout.undo_checkout(file, "not-the-holder", @dataset, true)
    # Lock cleared — the force-release landed.
    assert doc.content["checkedOutBy"] in [nil, ""]
  end

  test "a non-admin non-holder (admin? == false) is refused" do
    file = file_locked_by("someone-else")

    assert {:error, :forbidden} =
             Checkout.undo_checkout(file, "not-the-holder", @dataset, false)
  end

  test "the lock holder releases their own checkout even when admin? == false" do
    file = file_locked_by("me")

    assert {:ok, doc} = Checkout.undo_checkout(file, "me", @dataset, false)
    assert doc.content["checkedOutBy"] in [nil, ""]
  end
end
