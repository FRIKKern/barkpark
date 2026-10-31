defmodule Barkpark.PortableDoc.GoldenPackTest do
  @moduledoc """
  Freshness lock for the PortableDoc golden pack (`api/priv/portable_doc/goldens/`):
  the committed bytes equal a fresh `Pack.build/0`, file for file, and the pack
  holds what it promises. Only the stamp's `barkpark_sha` may differ (a commit
  moves HEAD). Regenerate with `MIX_ENV=test mix barkpark.portable_doc.gen_pd_parity`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Stylesheet
  alias Mix.Tasks.Barkpark.PortableDoc.GenPdParity
  alias Mix.Tasks.Barkpark.PortableDoc.GenPdParity.Pack

  @regen "run `MIX_ENV=test mix barkpark.portable_doc.gen_pd_parity`"

  # The pack syncs to a public repo: no owner names, no internal hosts.
  @private ~r/jarl|pelle|frikk|guerrilla|barkpark-cp|157\.180\.|178\.105\.|89\.167\./i

  setup_all do
    committed =
      Pack.dir()
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&File.dir?/1)
      |> Map.new(&{Path.relative_to(&1, Pack.dir()), File.read!(&1)})

    %{committed: committed, fresh: Pack.build()}
  end

  test "the committed pack holds exactly the files a fresh build writes", %{
    committed: c,
    fresh: f
  } do
    assert Enum.sort(Map.keys(c)) == Enum.sort(Map.keys(f)),
           "the pack's file set is stale — #{@regen}"
  end

  test "every committed file but the stamp is byte-identical to a fresh build", %{
    committed: c,
    fresh: f
  } do
    stale = for {path, bytes} <- f, path != "stamp.json", c[path] != bytes, do: path
    assert stale == [], "stale pack files #{inspect(stale)} — #{@regen}"
  end

  test "the stamp matches a fresh build apart from the commit sha", %{committed: c, fresh: f} do
    committed = Jason.decode!(c["stamp.json"])
    assert committed["barkpark_sha"] =~ ~r/\A[0-9a-f]{40}\z/

    assert Map.delete(committed, "barkpark_sha") ==
             Map.delete(Jason.decode!(f["stamp.json"]), "barkpark_sha")
  end

  test "the stamp names the render version, the served CSS, the gettext catalogues and every file",
       %{fresh: f} do
    stamp = Jason.decode!(f["stamp.json"])
    assert stamp["render_version"] == Render.body_html_render_version()

    assert stamp["stylesheet_sha256"] ==
             :crypto.hash(:sha256, Stylesheet.css()) |> Base.encode16(case: :lower)

    assert stamp["gettext_sha256"] =~ ~r/\A[0-9a-f]{64}\z/

    assert Enum.sort(Map.keys(stamp["files"])) ==
             f |> Map.keys() |> List.delete("stamp.json") |> Enum.sort()

    for {path, sha} <- stamp["files"],
        do: assert(sha == :crypto.hash(:sha256, f[path]) |> Base.encode16(case: :lower), path)
  end

  test "the pack holds every part, none of them empty", %{committed: c} do
    count = fn prefix -> Enum.count(Map.keys(c), &String.starts_with?(&1, prefix)) end
    locales = length(Barkpark.Tenancy.known_locales())

    assert count.("blocks/") == 80
    assert count.("locales/") == locales
    assert count.("pages/") == 2 * locales
    assert count.("i18n/") == locales
    assert count.("ops/") == 9

    for path <- ~w(stamp.json fragments.json email.html css/paper-surface.css css/code-tokens.css
                   nested-list-carriers.json canvas-forbidden-classes.json),
        do: assert(byte_size(Map.get(c, path, "")) > 0, "#{path} is missing or empty")

    for {path, bytes} <- c, do: assert(byte_size(bytes) > 0, "#{path} is empty")
  end

  test "each per-type golden decodes equal to its api mirror", %{committed: c} do
    for type <- GenPdParity.types() do
      mirror = Path.join(hd(GenPdParity.mirror_dirs()), GenPdParity.filename(type))

      assert Jason.decode!(c["blocks/#{GenPdParity.filename(type)}"]) ==
               Jason.decode!(File.read!(mirror)),
             type
    end
  end

  test "every reader page carries its theme, lang, the pinned nonce and every block", %{
    committed: c
  } do
    for locale <- Barkpark.Tenancy.known_locales(), theme <- ~w(light dark) do
      page = c["pages/#{theme}-#{locale}.html"]
      assert page =~ ~s(<html data-theme="#{theme}" data-bp-theme="evergreen" lang="#{locale}">)
      assert page =~ ~s(content="pack-csrf-token")
      assert page =~ ~s(nonce="parity-nonce")
      assert page =~ Stylesheet.css()

      for type <- GenPdParity.types(),
          do: assert(page =~ ~s(data-block-id="#{type}"), "#{theme}-#{locale}: #{type}")
    end
  end

  test "the fragments map paints every in-scope type, a figure as its child", %{committed: c} do
    fragments = Jason.decode!(c["fragments.json"])
    assert Enum.sort(Map.keys(fragments)) == GenPdParity.types()
    child = GenPdParity.input("figure")["child"]
    assert fragments["figure"] == Render.render_block(child, %{style: :article})
  end

  test "the i18n maps carry the canvas words in each locale", %{committed: c} do
    en = Jason.decode!(c["i18n/paper-canvas.en.json"])
    nb = Jason.decode!(c["i18n/paper-canvas.nb-NO.json"])
    assert Map.keys(en) == Map.keys(nb)
    assert map_size(en) > 100
    assert en["Yes"] == "Yes"
    assert nb["Yes"] == "Ja"
  end

  test "building the pack leaves the caller's CSRF token alone" do
    Process.put(:plug_masked_csrf_token, "caller-token")
    Pack.build()
    assert Plug.CSRFProtection.get_csrf_token() == "caller-token"
  end

  test "no pack file names an owner or an internal host", %{committed: c} do
    leaks = for {path, bytes} <- c, Regex.match?(@private, bytes), do: path
    assert leaks == [], "pack files leak private names: #{inspect(leaks)}"
  end
end
