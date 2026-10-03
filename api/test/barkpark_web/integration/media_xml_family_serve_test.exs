defmodule BarkparkWeb.Integration.MediaXmlFamilyServeTest do
  @moduledoc """
  task-22c9cb88ff4f6076 — `MediaFile.dangerous_mime?/1` named a fixed list (svg, html,
  xhtml, text/xml, application/xml, js). Every OTHER XML MIME type passed: a
  `.rss` or `.atom` upload whose bytes do not sniff as svg/html is stored as
  `application/rss+xml` / `application/atom+xml` (the extension's type) and
  `/media/files/*` served it INLINE from the app origin.

  The WHATWG MIME Sniffing standard defines an XML MIME type as any type whose
  subtype ends in `+xml`, or whose essence is `text/xml` / `application/xml`.
  A browser renders such a response as an XML document, and an element in the
  XHTML namespace (`<h:script>`) executes — stored XSS on the API/Studio
  origin, from any principal holding a write key.

  The dangerous family now covers every `+xml` subtype plus the XSLT types, so
  these collapse to `application/octet-stream` + `attachment` + `nosniff` like
  svg/html already do.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  alias Barkpark.{Auth, Media}
  alias Barkpark.Media.Storage.MediaFile

  @ds "production"
  @payload ~s[<?xml version="1.0"?><rss xmlns:h="http://www.w3.org/1999/xhtml"><h:script>alert(document.domain)</h:script></rss>]

  setup do
    Auth.create_token("xml-family-admin", "xml family", @ds, ["read", "write", "admin"])
    Barkpark.TenancyFixtures.ensure_default_scope!()
    :ok
  end

  defp upload_and_fetch(conn, ext) do
    path = Path.join(System.tmp_dir!(), "xmlfam-#{System.unique_integer([:positive])}.#{ext}")
    File.write!(path, @payload)
    on_exit(fn -> File.rm(path) end)

    result =
      conn
      |> put_req_header("authorization", "Bearer xml-family-admin")
      |> post("/v1/media/#{@ds}/upload", %{
        "file" => %Plug.Upload{path: path, filename: "feed.#{ext}", content_type: "text/plain"}
      })
      |> json_response(201)
      |> Map.fetch!("result")

    on_exit(fn -> File.rm(Path.join(Media.upload_dir(), result["path"])) end)

    scoped_conn() |> get(URI.parse(result["url"]).path)
  end

  for ext <- ~w(rss atom) do
    test "a .#{ext} XML upload is never served inline as an XML type", %{conn: conn} do
      served = upload_and_fetch(conn, unquote(ext))

      assert served.status == 200
      [ct] = get_resp_header(served, "content-type")
      refute ct =~ "xml", "served as an XML MIME type: #{ct}"
      assert get_resp_header(served, "content-disposition") == ["attachment"]
      assert get_resp_header(served, "x-content-type-options") == ["nosniff"]
    end
  end

  test "the dangerous family is the WHATWG XML MIME type set plus the existing members" do
    for mime <- ~w(application/rss+xml application/atom+xml application/rdf+xml
                   application/mathml+xml image/svg+xml application/xslt+xml text/xsl
                   text/xml application/xml text/html application/javascript) do
      assert MediaFile.dangerous_mime?(mime), "#{mime} must be dangerous"
    end

    for mime <- ~w(image/png image/jpeg application/pdf video/mp4 text/plain application/json) do
      refute MediaFile.dangerous_mime?(mime), "#{mime} must stay servable inline"
    end
  end
end
