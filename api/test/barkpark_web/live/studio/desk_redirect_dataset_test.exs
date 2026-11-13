defmodule BarkparkWeb.Studio.DeskRedirectDatasetTest do
  @moduledoc """
  task-f8383ce8dd2ef270 criterion 3: the desk sends a visitor who is not an
  admin to the Studio of the dataset the request named. The dataset went into
  the Location as it stood, so `production%FF` (text: the router had decoded
  `%25FF`) became the byte 0xFF on the next request, and `pro/duction`
  another path.
  """
  use BarkparkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-redirect-#{System.unique_integer([:positive])}"
    {:ok, _} = Barkpark.Auth.create_token(raw, "desk-redirect", "production", ~w(read), ws.id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     scope: "/w/#{ws.slug}/p/#{proj.slug}"}
  end

  test "the redirect names the dataset the request named", %{conn: conn, scope: scope} do
    for dataset <- ["production", "production%FF", "pro/duction", "a b", "a?b#c", "blåbær"] do
      segment = URI.encode(dataset, &URI.char_unreserved?/1)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "#{scope}/d/#{segment}/studio/_desk")

      assert [^scope, rest] = String.split(to, "/d/", parts: 2)
      assert [named, "studio"] = String.split(rest, "/")
      assert URI.decode(named) == dataset
    end

    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, "#{scope}/d/production/studio/_desk")

    assert to == "#{scope}/d/production/studio"
  end
end
