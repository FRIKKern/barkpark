defmodule BarkparkWeb.Layouts.BulldocsLightboxContractTest do
  use ExUnit.Case, async: true

  @layout Path.expand("../../../lib/barkpark_web/layouts/bulldocs.html.heex", __DIR__)

  setup_all do
    {:ok, source: File.read!(@layout)}
  end

  test "reader ships one semantic image dialog", %{source: source} do
    assert source =~ ~s|<dialog id="bp-image-lightbox"|
    assert source =~ ~s|class="bp-image-lightbox__image" src="" alt=""|
    assert source =~ ~s|aria-label="Close enlarged image"|
    refute source =~ "onclick="
  end

  test "paper images open progressively with their selected asset", %{source: source} do
    assert source =~ ~s|document.querySelector(".bp-paper-article")|
    assert source =~ ~s|event.target.closest("img")|
    assert source =~ "lightboxImg.src = image.currentSrc || image.src"

    assert source =~ "lightboxImg.alt = image.alt || \"\""
    assert source =~ "dialog.showModal()"
  end

  test "keyboard and streamed images retain the lightbox behavior", %{source: source} do
    assert source =~ "image.tabIndex = 0"
    assert source =~ ~s|image.setAttribute("role", "button")|
    assert source =~ ~s|event.key !== "Enter" && event.key !== " "|
    assert source =~ "new MutationObserver"
    assert source =~ ~s|article.addEventListener("click"|
    assert source =~ ~s|dialog.addEventListener("cancel"|
    assert source =~ "trigger.focus()"
  end

  test "comparison evidence and clip controls use the editorial reader treatment", %{
    source: source
  } do
    assert source =~ "--bp-evidence-band: 1180px"
    assert source =~ "--bp-evidence-band-max: 1360px"
    assert source =~ ~s|[data-block-id*="-clip-"]:has(> .bp-button)|
    assert source =~ ".bp-paper-article figure > .bp-cols"
    assert source =~ "grid-template-columns: 1fr"
  end
end
