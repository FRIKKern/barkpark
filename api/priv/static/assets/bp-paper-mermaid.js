// bp-paper-mermaid.js — THE Mermaid runtime for `diagram` blocks.
//
// One hook, one palette, for every surface that paints a `pre.mermaid`:
// the Studio Claude chat transcript (root.html.heex) AND the Bulldocs papers
// reader (layouts/bulldocs.html.heex). The reader carried a byte-identical
// inline copy of the hook + palette until task-e96ac3b80506cf32 pointed it
// here; do not fork it again.
//
// Defines `window.BarkparkPaperMermaid`: a LiveView hook (mounted/updated →
// runMermaid) PLUS three seams a consumer may override BEFORE `load`:
//
//   * `isDark()`   — how this surface decides dark vs light. Default: the raw
//                    `prefers-color-scheme` query (what Studio chat wants).
//                    The reader replaces it with its effective-mode reader
//                    (the pre-paint `html[data-theme]` stamp wins over the OS).
//   * `autoScheme` — whether an OS scheme flip alone re-renders. Default true.
//                    The reader sets it false and drives `rerenderAll()` from
//                    its own `bp:mode` event, which fires for a toggle click
//                    AND for an OS flip that actually changes effective mode —
//                    never for a no-op OS flip under a stored choice.
//   * `init()` / `rerenderAll()` — re-initialise the engine under the current
//                    `isDark()`, and re-render every processed diagram from its
//                    stashed source (mermaid bakes the palette into the SVG).
//
// runAsciicast (asciinema) is deliberately NOT here: it is reader-only and
// stays in the reader's own hook, so Studio chat never pays for a player it
// does not paint.
//
// mermaid.min.js loads `defer` (Golden Rule #4: never a blocking script in
// <head>), so every entry point re-checks for `window.mermaid` and retries on
// the window load event.
(function () {
  const mono =
    "'SF Mono', ui-monospace, 'JetBrains Mono', Menlo, Consolas, monospace";

  // Literals, not CSS vars: mermaid bakes colors into the SVG at render time.
  // The scheme listener below re-renders from stashed source on palette flip.
  function themeVariables(dark) {
    if (dark) {
      return {
        fontFamily: mono, fontSize: "14px",
        background: "#0e1614", mainBkg: "#131d19",
        primaryColor: "#131d19", primaryTextColor: "#e7ede9",
        primaryBorderColor: "#45b394", nodeBorder: "#45b394",
        lineColor: "#9aaaa3", textColor: "#e7ede9", titleColor: "#e7ede9",
        secondaryColor: "#1a2b25", tertiaryColor: "#131d19",
        clusterBkg: "#0e1614", clusterBorder: "rgba(231,237,233,0.2)",
        edgeLabelBackground: "#0e1614",
        actorBkg: "#131d19", actorBorder: "#45b394",
        actorTextColor: "#e7ede9", actorLineColor: "#6c7a74",
        signalColor: "#9aaaa3", signalTextColor: "#e7ede9",
        labelBoxBkgColor: "#131d19", labelBoxBorderColor: "#45b394",
        labelTextColor: "#e7ede9", loopTextColor: "#e7ede9",
        noteBkgColor: "#1c2620", noteBorderColor: "#6c7a74",
        noteTextColor: "#e7ede9"
      };
    }
    return {
      fontFamily: mono, fontSize: "14px",
      background: "#f6faf9", mainBkg: "#eaf1ee",
      primaryColor: "#eaf1ee", primaryTextColor: "#15211d",
      primaryBorderColor: "#1e5347", nodeBorder: "#1e5347",
      lineColor: "#55635e", textColor: "#15211d", titleColor: "#15211d",
      secondaryColor: "#d7e8e1", tertiaryColor: "#f6faf9",
      clusterBkg: "#f6faf9", clusterBorder: "#dde7e2",
      edgeLabelBackground: "#f6faf9",
      actorBkg: "#eaf1ee", actorBorder: "#1e5347",
      actorTextColor: "#15211d", actorLineColor: "#82918b",
      signalColor: "#55635e", signalTextColor: "#15211d",
      labelBoxBkgColor: "#eaf1ee", labelBoxBorderColor: "#1e5347",
      labelTextColor: "#15211d", loopTextColor: "#15211d",
      noteBkgColor: "#e6f0eb", noteBorderColor: "#82918b",
      noteTextColor: "#15211d"
    };
  }

  const scheme = window.matchMedia("(prefers-color-scheme: dark)");

  // Legibility floor (probe-figure-fidelity-2026-08-12): with useMaxWidth the
  // engine emits width="100%" and stamps the diagram's NATURAL width as an
  // inline max-width, so a wide diagram in a narrow pane scales its 14-16px
  // labels down to ~4px. Promote that natural width to the svg's width and
  // make the host <pre> a scroll container: text always paints at its
  // authored size and the diagram scrolls instead of shrinking.
  function unshrink(nodes) {
    nodes.forEach((pre) => {
      pre.querySelectorAll("svg").forEach((svg) => {
        if (svg.style.maxWidth) {
          svg.style.width = svg.style.maxWidth;
          // A flex host would shrink the svg right back; opt out.
          svg.style.flex = "none";
          pre.style.overflowX = "auto";
          pre.style.maxWidth = "100%";
        }
      });
    });
  }

  // mermaid.run resolves after the svg lands in the DOM; `finally` keeps a
  // parse failure surfacing exactly as before (unshrink is a no-op then).
  function runAndUnshrink(nodes) {
    Promise.resolve(window.mermaid.run({ nodes })).finally(() =>
      unshrink(nodes)
    );
  }

  function initMermaid() {
    if (window.mermaid && window.mermaid.initialize) {
      window.mermaid.initialize({
        startOnLoad: false,
        theme: "base",
        themeVariables: themeVariables(api.isDark()),
        flowchart: { useMaxWidth: true },
        sequence: { useMaxWidth: true }
      });
    }
  }

  // Re-render every processed diagram from its stashed source under the
  // CURRENT palette — mermaid bakes the colors into the SVG, so a mode flip
  // would otherwise strand light diagrams on a dark page (and vice versa).
  function rerenderAll() {
    initMermaid();
    document.querySelectorAll("pre.mermaid[data-processed]").forEach((pre) => {
      if (pre.dataset.bpSrc != null) {
        pre.textContent = pre.dataset.bpSrc;
        pre.removeAttribute("data-processed");
      }
    });
    if (window.mermaid && window.mermaid.run) {
      runAndUnshrink(
        Array.from(
          document.querySelectorAll('pre.mermaid:not([data-processed="true"])')
        )
      );
    }
  }

  const api = {
    // Overridable seams — see the file header. A consumer replaces these
    // BEFORE the window load event; the deferred init below reads them then.
    isDark: () => scheme.matches,
    autoScheme: true,
    init: initMermaid,
    rerenderAll: rerenderAll,

    runMermaid() {
      const nodes = Array.from(
        this.el.querySelectorAll('pre.mermaid:not([data-processed="true"])')
      );
      if (!nodes.length) return;
      // Stash raw source before the first run — mermaid replaces the <pre>'s
      // text with the SVG; the scheme re-render needs the original.
      nodes.forEach((n) => {
        if (n.dataset.bpSrc == null) n.dataset.bpSrc = n.textContent;
      });
      if (window.mermaid && window.mermaid.run) {
        runAndUnshrink(nodes);
      } else {
        window.addEventListener(
          "load",
          () => {
            if (window.mermaid && window.mermaid.run) {
              runAndUnshrink(
                Array.from(
                  this.el.querySelectorAll('pre.mermaid:not([data-processed="true"])')
                )
              );
            }
          },
          { once: true }
        );
      }
    },
    mounted() {
      this.runMermaid();
    },
    updated() {
      this.runMermaid();
    }
  };

  window.BarkparkPaperMermaid = api;

  if (document.readyState === "complete") initMermaid();
  else window.addEventListener("load", initMermaid, { once: true });

  // An OS scheme flip re-renders only where the OS is the authority. A surface
  // with its own mode control (the reader) sets `autoScheme = false` and calls
  // `rerenderAll()` from its own event instead.
  scheme.addEventListener("change", () => {
    if (api.autoScheme) rerenderAll();
  });
})();
