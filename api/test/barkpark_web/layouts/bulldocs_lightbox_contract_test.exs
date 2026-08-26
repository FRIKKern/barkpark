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

  test "wide proof opens at original size with an explicit fit alternative and pan surface", %{
    source: source
  } do
    assert source =~ ~s|data-bp-lightbox-view="actual"|
    assert source =~ ~s|data-bp-lightbox-view="fit"|
    assert source =~ ~s|class="bp-image-lightbox__viewport" tabindex="0"|
    assert source =~ ~s|setView(ratio >= 2.2 ? "actual" : "fit")|
    assert source =~ "max-width: none"
    assert source =~ "viewport.scrollLeft = pan.left"
    assert source =~ ~s|viewport.addEventListener("pointermove"|
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
    assert source =~ ~r/\.bp-paper-shell\.bp-paper-article\s*\{[^}]*max-width: 660px/s
    refute source =~ ".bp-paper-article-wide"
    assert source =~ "--bp-evidence-band: 1180px"
    assert source =~ "--bp-evidence-band-max: 1360px"
    assert source =~ ~s|[data-block-id*="-clip-"]:has(> .bp-button)|
    assert source =~ "min-height: 44px"
    assert source =~ ".bp-paper-article figure > .bp-cols"
    assert source =~ "max-height: min(72vh, 760px)"
    assert source =~ "object-fit: contain"
    assert source =~ "grid-template-columns: 1fr"
  end

  test "task headings have a quiet editorial boundary", %{source: source} do
    assert source =~ ~s|#paper-body > [data-block-id]:has(> h3)|
    assert source =~ "border-top: 1px solid"
    assert source =~ "text-wrap: balance"
  end

  test "numbered chapter-map cards link to matching numbered section headings", %{
    source: source
  } do
    assert source =~ ~s|article.querySelectorAll('[data-block-id*="chapter-map"] .bp-card')|
    assert source =~ ~s|card.dataset.bpChapterTarget = target.id|
    assert source =~ ~s|card.setAttribute("role", "link")|
    assert source =~ ~s|history.replaceState(null, "", "#" + target.id)|
    assert source =~ ~s|window.matchMedia("(prefers-reduced-motion: reduce)")|

    assert source =~
             ~s|target.scrollIntoView({ behavior: reduced ? "auto" : "smooth", block: "start" })|

    assert source =~ ~s|.bp-card[data-bp-chapter-target]:focus-visible|
  end
end
