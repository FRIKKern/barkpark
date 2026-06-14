// bp-graph.js — thin client half of the Studio blast-radius graph pane
// (Goal ges/graph-edge-seam, Phase 5).
//
// Cytoscape owns ALL client layout. The server (Content.Graph.traverse/2 →
// the GraphView LiveComponent) derives the node/edge payloads and ships them
// as data-nodes / data-edges JSON on a STABLE-id div (#studio-graph). This
// hook parses them on mounted(), diffs via cy.json({elements}) on updated()
// (so navigation re-lays-out in place rather than remounting), and tears the
// instance down on destroyed().
//
// Loaded NON-DEFER at the bottom of body AFTER phoenix_live_view.js AND
// cytoscape.min.js, so the inline Hooks registration in root.html.heex can
// pick window.BarkparkGraph up before the LiveSocket connects:
// `Hooks.GraphPane = window.BarkparkGraph`. Golden Rule #4 (no blocking
// scripts in <head>) holds — this is bottom-of-body.
//
// Phantom nodes (phantom:true — dangling reference targets the FK can't
// store) render dashed/muted with a bare _id label and are NEVER expandable:
// the hook short-circuits any expansion request on them. Edge weight feeds
// Cytoscape thickness / spring length ONLY — the one place weight is consumed.
(function () {
  // Map the server node/edge payloads onto Cytoscape's {data:{…}} elements.
  function toElements(nodes, edges) {
    var els = [];

    (nodes || []).forEach(function (n) {
      // Phantom (ghost) nodes have no real `id` — key them off broken_id so
      // Cytoscape still has a unique node id, and flag them for styling.
      var id = n.phantom ? "phantom:" + (n.broken_id || n.title) : n.id;
      if (!id) return;

      els.push({
        group: "nodes",
        data: {
          id: id,
          label: n.title || n.doc_id || n.broken_id || id,
          type: n.type || "",
          phantom: n.phantom ? true : false,
          via_field: n.via_field || "",
          refType: n.refType || ""
        }
      });
    });

    (edges || []).forEach(function (e) {
      if (!e.from_id || !e.to_id) return;
      els.push({
        group: "edges",
        data: {
          id: "e:" + e.from_id + ":" + e.to_id + ":" + (e.kind || ""),
          source: e.from_id,
          target: e.to_id,
          kind: e.kind || "",
          // Layout-only: weight drives edge thickness + spring length, never
          // ranking (the server keeps ranking weight-free).
          weight: typeof e.weight === "number" ? e.weight : 1,
          plugin_source: e.plugin_source || ""
        }
      });
    });

    return els;
  }

  function readData(el) {
    var nodes = [];
    var edges = [];
    try {
      nodes = JSON.parse(el.dataset.nodes || "[]");
    } catch (_e) {
      nodes = [];
    }
    try {
      edges = JSON.parse(el.dataset.edges || "[]");
    } catch (_e) {
      edges = [];
    }
    return toElements(nodes, edges);
  }

  var STYLE = [
    {
      selector: "node",
      style: {
        "background-color": "#5b8def",
        label: "data(label)",
        "font-size": "10px",
        color: "#1f2937",
        "text-valign": "bottom",
        "text-margin-y": 4,
        width: 28,
        height: 28
      }
    },
    {
      // Phantom / dangling target — dashed border, muted, non-expandable.
      selector: "node[?phantom]",
      style: {
        "background-color": "#e5e7eb",
        "border-width": 2,
        "border-style": "dashed",
        "border-color": "#9ca3af",
        color: "#9ca3af",
        "font-style": "italic"
      }
    },
    {
      selector: "edge",
      style: {
        // Weight → thickness (LAYOUT-ONLY).
        width: "mapData(weight, 0, 5, 1, 6)",
        "line-color": "#cbd5e1",
        "target-arrow-color": "#cbd5e1",
        "target-arrow-shape": "triangle",
        "curve-style": "bezier"
      }
    }
  ];

  function layoutOpts() {
    // cose: a force-directed layout; edge weight feeds the spring length
    // (LAYOUT-ONLY consumption of weight).
    return {
      name: "cose",
      animate: false,
      edgeElasticity: function (edge) {
        return 100 * (edge.data("weight") || 1);
      }
    };
  }

  window.BarkparkGraph = {
    mounted() {
      if (typeof cytoscape !== "function") {
        // Cytoscape failed to load (vendored bundle missing). Degrade to a
        // visible note rather than throwing — the pane stays inert.
        this.el.textContent = "graph unavailable";
        return;
      }

      this._rev = this.el.dataset.rev;
      this._cy = cytoscape({
        container: this.el,
        elements: readData(this.el),
        style: STYLE,
        wheelSensitivity: 0.2
      });
      this._cy.layout(layoutOpts()).run();

      // A phantom node is non-expandable — swallow taps on it so no expansion
      // request is ever made for a dangling target.
      this._cy.on("tap", "node[?phantom]", function (evt) {
        evt.stopPropagation();
      });

      // Optional server push channel (graph-update) — re-key elements in place.
      this.handleEvent("graph-update", (payload) => {
        if (!this._cy || !payload) return;
        var els = toElements(payload.nodes, payload.edges);
        this._cy.json({ elements: els });
        this._cy.layout(layoutOpts()).run();
      });
    },

    updated() {
      if (!this._cy) return;
      // Diff only when the server bumped the rev — navigation changes the
      // data-* attrs on the SAME stable-id div, so the hook is updated (not
      // remounted) and the layout is preserved across nav.
      if (this.el.dataset.rev === this._rev) return;
      this._rev = this.el.dataset.rev;
      this._cy.json({ elements: readData(this.el) });
      this._cy.layout(layoutOpts()).run();
    },

    destroyed() {
      if (this._cy) {
        this._cy.destroy();
        this._cy = null;
      }
    }
  };
})();
