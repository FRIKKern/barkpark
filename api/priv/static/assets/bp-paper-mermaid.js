// bp-paper-mermaid.js — Mermaid runtime for `diagram` blocks OUTSIDE the
// Bulldocs reader (first consumer: the Studio Claude chat transcript).
//
// Defines `window.BarkparkPaperMermaid` (a LiveView hook) and initialises the
// mermaid engine in manual mode with the same evergreen `--paper-*` palette
// the papers reader bakes in (bulldocs.html.heex is the source of these
// literals; a shared-asset dedup so the reader consumes this file too is
// filed as follow-up — the reader's proven wiring stays untouched for now).
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
        themeVariables: themeVariables(scheme.matches),
        flowchart: { useMaxWidth: true },
        sequence: { useMaxWidth: true }
      });
    }
  }

  if (document.readyState === "complete") initMermaid();
  else window.addEventListener("load", initMermaid, { once: true });

  // Re-render every processed diagram from its stashed source when the OS
  // scheme flips — mermaid bakes the palette into the SVG.
  scheme.addEventListener("change", () => {
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
  });

  window.BarkparkPaperMermaid = {
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
})();
