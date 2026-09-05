// bp-paper-editor-hooks.js — the LiveView hooks of the Beta paper block editor
// (BarkparkWeb.Studio.StudioLive.Components.PaperEditor).
//
// ONE definition, two layouts. The Studio root layout (root.html.heex) and the
// public paper reader layout (bulldocs.html.heex) both merge this object into
// their own hooks map BEFORE `new LiveSocket(...)`:
//
//     Object.assign(Hooks, window.BarkparkPaperEditorHooks || {});
//
// Bodies are the ones root.html.heex carried inline until the reader needed
// them too; they touch only window/document/CSS, never a Studio-only global,
// so the same code runs on both surfaces. Load NON-defer, before the inline
// boot script that reads the global.

(function () {
  const Hooks = {};
  const PAPER_OP_RETRY_TTL_MS = 60 * 60 * 1000;
  // Finish local edits and wait for their save replies before unmounting the
  // editor. A refused save leaves the paper open with its server halt message.
  Hooks.BarkparkPaperEditToggle = {
    mounted() {
      this._dirtyForms = new Set();
      this._formVersions = new WeakMap();
      this._main = this.el.closest("main");
      this._onFormInput = (event) => {
        const form = event.target.closest?.(".bp-paper-edit-form[phx-change]");
        if (form && this._main.contains(form)) {
          this._formVersions.set(form, (this._formVersions.get(form) || 0) + 1);
          this._dirtyForms.add(form);
        }
      };
      this._main.addEventListener("input", this._onFormInput);
      this._main.addEventListener("change", this._onFormInput);
      this._onClick = async (event) => {
        if (this.el.dataset.editing !== "true") return;
        event.preventDefault();
        event.stopImmediatePropagation();
        if (this._saving) return;
        this._saving = true;
        this.el.disabled = true;
        this.el.setAttribute("aria-busy", "true");
        try {
          // Input can continue while a previous save is in flight. Drain again
          // after its acknowledgement before allowing the editor to unmount.
          while (this.el.isConnected) {
            const pending = [];
            this._main.querySelectorAll('[phx-hook="BarkparkPaperCanvas"], [phx-hook="BarkparkPaperEditor"], [phx-hook="BarkparkFieldBlockBridge"], [phx-hook="BarkparkFieldBridge"]').forEach((wrapper) => {
              wrapper.dispatchEvent(new CustomEvent("bp-flush-pending", {
                detail: { waitUntil: (promise) => pending.push(promise) },
              }));
            });
            const dirtyForms = [...this._dirtyForms];
            dirtyForms.forEach((form) => {
              this._dirtyForms.delete(form);
              if (!form.isConnected) return;
              const changeEvent = form.getAttribute("phx-change");
              if (!changeEvent) return;
              const target = form.getAttribute("phx-target") || form;
              const params = Object.fromEntries(new FormData(form));
              const version = this._formVersions.get(form) || 0;
              pending.push(
                this.pushEventTo(target, changeEvent, params)
                  .then((results) => results.length > 0 && results.every((result) =>
                    result.status === "fulfilled" && result.value?.reply?.saved === true
                  ))
                  .catch(() => false)
                  .then((saved) => {
                    if (
                      !saved && form.isConnected &&
                      this._formVersions.get(form) === version
                    ) this._dirtyForms.add(form);
                    return saved;
                  })
              );
            });
            if (pending.length === 0) {
              try {
                await this.pushEvent("paper-toggle-edit", {});
              } catch (_) {
                // A disconnected toggle is still editing; the finally block
                // restores the button so the user can explicitly retry.
              }
              break;
            }
            if (!(await Promise.all(pending)).every(Boolean)) break;
          }
        } finally {
          this._saving = false;
          this.el.disabled = false;
          this.el.removeAttribute("aria-busy");
        }
      };
      this.el.addEventListener("click", this._onClick, true);
    },
    destroyed() {
      this.el.removeEventListener("click", this._onClick, true);
      this._main?.removeEventListener("input", this._onFormInput);
      this._main?.removeEventListener("change", this._onFormInput);
    },
  };

    // BarkparkPaperEditor — LV↔WC bridge for the per-block paper editor
    // (<bp-paper-editor>). Mounted on the phx-update="ignore" wrapper that
    // holds one custom element per rich-text block. The element emits a
    // bubbling + composed `bp-op` CustomEvent whose detail is a portable-doc
    // op ({op:"patch-block", id, patch}); we forward it verbatim to the
    // server's `paper-op` handler. The server owns the model — no client
    // state, no echo back into the WC.
    Hooks.BarkparkPaperEditor = {
      mounted() {
        this._pendingSaves = new Set();
        this._retryOp = null;
        const pushOp = (op) => {
          this._retryOp = op;
          const pending = this.pushEvent("paper-op", op)
            .then((reply) => reply?.saved === true)
            .catch(() => false)
            .then((saved) => {
              if (saved && this._retryOp === op) this._retryOp = null;
              return saved;
            })
            .finally(() => this._pendingSaves.delete(pending));
          this._pendingSaves.add(pending);
        };
        this._onOp = (e) => pushOp(e.detail);
        this.el.addEventListener("bp-op", this._onOp);
        this._onFlushPending = (event) => {
          this.el.querySelector("bp-paper-editor")?.flushPendingChanges?.();
          if (!this._pendingSaves.size && this._retryOp) pushOp(this._retryOp);
          if (this._pendingSaves.size) {
            event.detail.waitUntil(Promise.all([...this._pendingSaves]).then((results) => results.every(Boolean)));
          }
        };
        this.el.addEventListener("bp-flush-pending", this._onFlushPending);

        // Slash menu (P3.3): the WC emits a bubbling/composed `bp-slash-insert`
        // CustomEvent {detail:{type, afterId}} when the user picks a block type
        // from the "/" popup. Forward it verbatim to the server's
        // paper-slash-insert handler, which builds the block (default_block +
        // insert-after) through the SAME paper_op pipeline patch-block uses.
        this._onSlash = (e) => {
          this.pushEvent("paper-slash-insert", e.detail);
        };
        this.el.addEventListener("bp-slash-insert", this._onSlash);

        // Wikilink autocomplete (P3.x): the WC owns the [[ popup and all
        // trigger detection (parseOpenWikilink from wikilink-trigger.js).
        // This hook only supplies candidates by round-tripping the live query
        // to the server's `paper-wikilink-search` reply-event, which returns
        // {results:[{title, id, type}]}. The WC property `wikilinkSource` is
        // the injectable async source; when unset the popup never opens.
        // Custom-element upgrade timing: the WC is server-rendered and already
        // present in the DOM on mount (same as the bp:block-update handler
        // below that queries it identically). We also register via
        // customElements.whenDefined so the assignment lands even if the
        // registry hasn't processed the tag yet, without assuming upgrade order.
        const wc = this.el.querySelector("bp-paper-editor");
        const wireWikilinkSource = (el) => {
          el.wikilinkSource = (query) =>
            new Promise((resolve) =>
              this.pushEvent("paper-wikilink-search", { query }, (reply) =>
                resolve((reply && reply.results) || [])));
        };
        // #tag autocomplete (P3.x): same shape as wikilinkSource, mirrored.
        // The WC owns the # popup + all trigger detection (the tag sigil-
        // boundary check); this hook only supplies candidates by round-tripping
        // the live query to `paper-tag-search`, which replies {results:[name…]}
        // (plain tag-name strings). `el.tagSource` is the injectable async
        // source; unset → the popup never opens (read-mode / web embed).
        const wireTagSource = (el) => {
          el.tagSource = (query) =>
            new Promise((resolve) =>
              this.pushEvent("paper-tag-search", { query }, (reply) =>
                resolve((reply && reply.results) || [])));
        };
        if (wc) {
          wireWikilinkSource(wc);
          wireTagSource(wc);
        }
        customElements.whenDefined("bp-paper-editor").then(() => {
          const el = this.el.querySelector("bp-paper-editor");
          if (el) {
            wireWikilinkSource(el);
            wireTagSource(el);
          }
        });

        // Inbound bridge: external broadcasts → in-place editor re-mount.
        // The wrapper carries `phx-update="ignore"` (caret preservation), so
        // a delta from another agent / the ingest endpoint never patches the
        // editor on its own. StudioLive's handle_info({:paper_block,…}) pushes
        // `bp:block-update` {block_id, block} via push_event/3; this listener
        // filters by element id ("paper-ed-<block_id>") and calls the WC's
        // `block` property setter, which calls `editor.commands.setContent(...)`
        // to swap the TipTap document in place. The cursor is preserved across
        // OTHER blocks' updates because we only touch the WC whose id matches.
        // A self-originating echo lands here with the same content the WC just
        // emitted, so setContent is a visual no-op.
        this._onBlockUpdate = (payload) => {
          if (!payload || !payload.block_id) return;
          if (this.el.id !== `paper-ed-${payload.block_id}`) return; // not my block
          const wc = this.el.querySelector("bp-paper-editor");
          if (!wc) return;
          wc.block = payload.block;
        };
        this.handleEvent("bp:block-update", this._onBlockUpdate);
      },
      destroyed() {
        this.el.removeEventListener("bp-op", this._onOp);
        this.el.removeEventListener("bp-flush-pending", this._onFlushPending);
        this.el.removeEventListener("bp-slash-insert", this._onSlash);
      }
    };

    // BarkparkPaperCanvas — Phase-4 S2 LV↔WC bridge for the CONTINUOUS canvas
    // (<bp-paper-canvas>). Mounted on the phx-update="ignore" wrapper that holds
    // ONE custom element per maximal PROSE RUN (paragraph|heading|list). On mount
    // it reads the run's blocks from the wrapper's `data-canvas-blocks` attribute
    // (JSON) and assigns them to `el.blocks` (the element re-projects the whole
    // run into its single ProseMirror document). The element emits a bubbling +
    // composed `bp-canvas-ops` CustomEvent whose detail is {ops:[…]} — an ORDERED
    // portable-doc op array (the run's cumulative diff). We forward detail verbatim
    // to the server's `paper-ops` handler, which folds it through the SAME
    // Patch.apply_patches + persist path the per-block `paper-op` uses. The server
    // owns the model. Structure mirrors BarkparkPaperEditor; the existing editor
    // hook is untouched (this is additive).
    Hooks.BarkparkPaperCanvas = {
      mounted() {
        // Seed the run into the element. Pre-upgrade-safe: assigning `el.blocks`
        // before the custom-element definition upgrades the node lands as a plain
        // own-property the element's connectedCallback reclaims (see the WC's
        // _upgradeProperty). So set it whether or not the tag has upgraded yet.
        const seedBlocks = (el) => {
          if (!el) return;
          const raw = this.el.dataset.canvasBlocks;
          if (!raw) return;
          try {
            el.blocks = JSON.parse(raw);
          } catch (_e) {
            // Malformed payload — leave the element on its empty default rather
            // than throw out of the hook's mount.
          }
        };
        // PICKER FETCH-SCOPE (run-splitter tail): a field-image / field-reference
        // riding this run mounts its client-side picker WC (bp-media-picker /
        // bp-reference-picker) inside a canvas node-view; the node-view reads the
        // dataset + bearer token off the <bp-paper-canvas> HOST element (data-dataset
        // / data-token / data-scope-prefix) — the SAME scope the per-block picker
        // render uses. Item-share-only editors carry data-picker-browse=false so
        // they retain the current value without gaining a dataset browser.
        const seedScope = (el) => {
          if (!el) return;
          const ds = this.el.dataset.canvasDataset;
          const tok = this.el.dataset.canvasToken;
          const prefix = this.el.dataset.canvasScopePrefix;
          const pickerBrowse = this.el.dataset.canvasPickerBrowse;
          if (ds != null) el.setAttribute("data-dataset", ds);
          if (tok != null) el.setAttribute("data-token", tok);
          if (prefix != null) el.setAttribute("data-scope-prefix", prefix);
          if (pickerBrowse != null) el.setAttribute("data-picker-browse", pickerBrowse);
          // pdd-t2: the block AFTER this run in the full document is template-
          // locked (e.g. the featured image right after the title run). The WC's
          // filterTransaction reads data-locked-tail LIVE and vetoes any run
          // GROWTH — a new node here would displace that locked follower.
          const lockedTail = this.el.dataset.canvasLockedTail;
          if (lockedTail != null) el.setAttribute("data-locked-tail", lockedTail);
          // pdd-t20c: the doc's CONSTRAINT VOCABULARY (JSON-encoded
          // Template.paper_declarations(), stamped only for docs that carry locked
          // blocks). The WC's filterTransaction reads data-constraints LIVE and
          // vetoes a remove/move that breaks a cardinality or relative-order
          // declaration — the calm lock veto generalized (twin of data-locked-tail).
          const constraints = this.el.dataset.canvasConstraints;
          if (constraints != null) el.setAttribute("data-constraints", constraints);
        };
        const wc = this.el.querySelector("bp-paper-canvas");
        if (wc) wc.acknowledgedSaves = true;
        seedScope(wc);
        seedBlocks(wc);

        // P4 [[ wikilink + # tag autocomplete: inject the SAME async candidate
        // sources the per-block BarkparkPaperEditor hook injects (copied verbatim).
        // The canvas WC owns the popups + all trigger detection (parseOpenWikilink
        // / parseOpenTag); this hook only supplies candidates by round-tripping the
        // live query to the SERVER's existing `paper-wikilink-search` /
        // `paper-tag-search` reply-events (which return {results:[{title,id,type}]}
        // and {results:[name…]} respectively — reused verbatim, no new handlers).
        // The `wikilinkSource` / `tagSource` WC properties are the injectable async
        // sources; when unset the popups never open. Set them whether or not the tag
        // has upgraded (the WC's _upgradeProperty reclaims a pre-upgrade assignment),
        // and again via whenDefined so the assignment lands without assuming order.
        const wireWikilinkSource = (el) => {
          el.wikilinkSource = (query) =>
            new Promise((resolve) =>
              this.pushEvent("paper-wikilink-search", { query }, (reply) =>
                resolve((reply && reply.results) || [])));
        };
        const wireTagSource = (el) => {
          el.tagSource = (query) =>
            new Promise((resolve) =>
              this.pushEvent("paper-tag-search", { query }, (reply) =>
                resolve((reply && reply.results) || [])));
        };
        if (wc) {
          wireWikilinkSource(wc);
          wireTagSource(wc);
        }
        customElements.whenDefined("bp-paper-canvas").then(() => {
          const el = this.el.querySelector("bp-paper-canvas");
          if (el) {
            el.acknowledgedSaves = true;
            seedScope(el);
            seedBlocks(el);
            wireWikilinkSource(el);
            wireTagSource(el);
            this._repaintFleet?.();
          }
        });

        // Outbound: the canvas's debounced op batch → the server's paper-ops
        // handler. detail is {ops:[…]}; forward it verbatim.
        this._pendingSaves = new Set();
        this._opsQueue = [];
        this._sendingOps = false;
        this._opsFailed = false;
        this._saveBridgeDestroyed = false;
        const paperOpsRequestId = () => {
          try {
            const crypto = window.crypto;
            const requestId = crypto?.randomUUID?.();
            if (typeof requestId === "string" && requestId !== "") return requestId;
            if (typeof crypto?.getRandomValues !== "function") return null;
            const bytes = crypto.getRandomValues(new Uint8Array(16));
            bytes[6] = (bytes[6] & 0x0f) | 0x40;
            bytes[8] = (bytes[8] & 0x3f) | 0x80;
            const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0"));
            return [
              hex.slice(0, 4).join(""),
              hex.slice(4, 6).join(""),
              hex.slice(6, 8).join(""),
              hex.slice(8, 10).join(""),
              hex.slice(10, 16).join(""),
            ].join("-");
          } catch (_) {
            return null;
          }
        };
        const reportUnretryableOps = (entry, code, message) => {
          this._opsFailed = true;
          entry.unretryable = true;
          const status = this.el.closest("main")?.querySelector(
            '[data-test-id="bp-paper-footer-save"][role="status"]',
          );
          if (status) status.textContent = message;
          if (entry.errorReported) return;
          entry.errorReported = true;
          this.el.dispatchEvent(new CustomEvent("bp-error", {
            detail: { code, error: message },
            bubbles: true,
            composed: true,
          }));
        };
        const sendNextOps = () => {
          if (
            this._saveBridgeDestroyed || this._sendingOps ||
            this._opsFailed || !this._opsQueue.length
          ) return;
          const entry = this._opsQueue[0];
          if (!entry.requestId) {
            reportUnretryableOps(
              entry,
              "paper_ops_request_id_unavailable",
              "Save paused: this browser cannot create a safe retry ID. Your edits are still here.",
            );
            return;
          }
          if (Date.now() >= entry.expiresAt) {
            reportUnretryableOps(
              entry,
              "paper_ops_retry_expired",
              "Save paused after one hour of retries. Unsaved work remains here; copy it before reloading.",
            );
            return;
          }
          this._sendingOps = true;
          const pending = this.pushEvent("paper-ops", {
            ops: entry.ops,
            request_id: entry.requestId,
          })
            .then((reply) =>
              reply?.saved === true && reply?.request_id === entry.requestId
            )
            .catch(() => false)
            .then((saved) => {
              this._sendingOps = false;
              if (saved && this._opsQueue[0] === entry) {
                // Remove the acknowledged head before notifying the WC. That
                // notification may synchronously emit the next dirty delta.
                this._opsQueue.shift();
              }
              const canvas = this.el.querySelector("bp-paper-canvas");
              if (entry.seq != null && typeof canvas?.acknowledgeOps === "function") {
                canvas.acknowledgeOps(entry.seq, saved);
              }
              if (saved) {
                sendNextOps();
              } else {
                // Retain the failed head and every later delta behind it. The
                // next explicit View retries in order, so a later source-mode
                // success can never erase an earlier unsatisfied rich batch.
                this._opsFailed = true;
              }
              return saved;
            })
            .finally(() => this._pendingSaves.delete(pending));
          this._pendingSaves.add(pending);
        };
        this._onCanvasOps = (e) => {
          this._opsQueue.push({
            ops: e.detail.ops,
            seq: e.detail.seq,
            requestId: paperOpsRequestId(),
            expiresAt: Date.now() + PAPER_OP_RETRY_TTL_MS,
          });
          sendNextOps();
        };
        this.el.addEventListener("bp-canvas-ops", this._onCanvasOps);
        this._onFlushPending = (event) => {
          const wc = this.el.querySelector("bp-paper-canvas");
          wc?.flushPendingChanges?.();
          if (this._opsFailed && !this._sendingOps) {
            this._opsFailed = false;
            sendNextOps();
          }
          if (this._pendingSaves.size) {
            event.detail.waitUntil(Promise.all([...this._pendingSaves]).then((results) => results.every(Boolean)));
          } else if (this._opsQueue.length) {
            // An expired batch (or a browser without secure UUID support) is
            // intentionally retained. Keep View mounted so the local document
            // remains available to copy or recover instead of silently losing it.
            event.detail.waitUntil(Promise.resolve(false));
          }
        };
        this.el.addEventListener("bp-flush-pending", this._onFlushPending);

        // Inbound bridge (S4a): the echo-driven baseline advance — the
        // bp:block-update successor for the continuous canvas. After the server
        // applies a paper-ops batch it re-partitions the CONFIRMED blocks and
        // pushes `bp:canvas-update` {runs:[{run_id, blocks}, …]} via push_event/3,
        // ONE entry per prose RUN keyed exactly as the wrapper is
        // ("paper-canvas-"<>run_id, where run_id is the paper's SLUG + the run's
        // ORDINAL, "<slug>-run-<i>" — Bug #1a: the ordinal is a STABLE id that
        // survives a leading-block delete, NOT the mutable first-block id; Bug #1c:
        // the slug keeps ids unique ACROSS papers so a patch-navigation can never
        // transplant a stale canvas. The prefix keeps the first run's id truthy so
        // the `!run.run_id` guard below never drops it). This listener filters to the run
        // whose wrapper id matches and calls the WC's
        // applyServerBlocks(blocks):
        //   - the OWN-ECHO common case (the user just made this edit, the server
        //     confirmed the SAME blocks) is a pure baseline RESET inside the WC —
        //     no editor mutation, no caret movement (the WC diffs the confirmed
        //     blocks against its live doc and no-ops when they match);
        //   - an EXTERNAL edit (different blocks) updates the editor to the
        //     confirmed content (addToHistory:false; focus/IME-guarded inside the
        //     WC). A run not currently mounted (id changed) finds no matching
        //     wrapper and is skipped — LiveView's own re-render remounts it from
        //     data-canvas-blocks. Mirrors the BarkparkPaperEditor bp:block-update
        //     handler's structure (filter by element id, call the WC method).
        this._onCanvasUpdate = (payload) => {
          if (!payload || !Array.isArray(payload.runs)) return;
          payload.runs.forEach((run) => {
            if (!run || !run.run_id) return;
            if (this.el.id !== `paper-canvas-${run.run_id}`) return; // not my run
            const wc = this.el.querySelector("bp-paper-canvas");
            if (!wc || typeof wc.applyServerBlocks !== "function") return;
            wc.applyServerBlocks(run.blocks);
          });
        };
        this.handleEvent("bp:canvas-update", this._onCanvasUpdate);

        // t9 — LIVE TASK-BLOCK PREVIEW (parallel display channel). The server
        // resolves every query-carrying task block into id-keyed rows and pushes
        // `bp:task-preview` {previews:[{block_id, type, snapshot|task|error}, …]}
        // — SEPARATE from bp:canvas-update (which carries the SAVE baseline). This
        // channel is DISPLAY ONLY: the previews never enter el.blocks / the diff
        // baseline, so a save right after a preview emits ZERO ops (doctrine D5).
        // t12a: task blocks now ride canvas RUNS as bpFleet read-only atoms —
        // their DISPLAY paint arrives server-rendered on `bp:block-html` (below),
        // and the boundary-widget consumer (`task_block_preview/1`,
        // paper_editor.ex) is dormant in the flag-ON paper pane (retained
        // infra). This channel stays as the row-level twin: we hand the previews
        // to the WC's applyTaskPreviews(previews) if it implements one
        // (progressive: a WC without the method — including today's — simply
        // ignores the rows and keeps its query stub, never a crash). Keyed by
        // block_id so a future node view could route rows directly.
        this._onTaskPreview = (payload) => {
          if (!payload || !Array.isArray(payload.previews)) return;
          const wc = this.el.querySelector("bp-paper-canvas");
          if (!wc || typeof wc.applyTaskPreviews !== "function") return;
          wc.applyTaskPreviews(payload.previews);
        };
        this.handleEvent("bp:task-preview", this._onTaskPreview);

        // pdd-t8 — FLEET-IN-CANVAS server paint. The server renders EVERY top-level
        // non-prose fleet block (task board / cards / pipeline / form / …) through
        // the reader's OWN producer (Render.render_block/2, style: :article — rule 3
        // / D8, one producer byte-for-byte) and pushes `bp:block-html`
        // {renders:[{block_id, html}, …]}. We inject each html into the matching
        // `bpFleet` node-view's paint hole (`[data-bp-fleet-id=<id>] [data-bp-fleet-
        // body]`) inside THIS run's WC. DISPLAY ONLY (D5): the HTML never enters
        // el.blocks / the diff baseline, so a save right after a paint emits ZERO ops
        // (D3). The renders are STASHED so a WC remount (LiveView re-render of
        // data-canvas-blocks) re-injects from the last paint rather than dropping
        // back to the loading chip. An empty html paints an honest empty note, never
        // a blank strip (mirrors task_block_preview/1's honesty).
        this._fleetRenders = {};
        this._paintFleet = (id, html) => {
          const hole = this.el.querySelector(
            `[data-bp-fleet-id="${(window.CSS && CSS.escape) ? CSS.escape(id) : id}"] [data-bp-fleet-body]`,
          );
          if (!hole) return; // this render's block is not in THIS run's WC
          if (typeof html === "string" && html.trim() !== "") {
            hole.innerHTML = html;
          } else {
            hole.innerHTML =
              '<div class="bp-canvas-readonly-chip">Nothing to show yet.</div>';
          }
        };
        this._onBlockHtml = (payload) => {
          if (!payload || !Array.isArray(payload.renders)) return;
          payload.renders.forEach((r) => {
            if (!r || r.block_id == null) return;
            this._fleetRenders[r.block_id] = r.html;
            this._paintFleet(r.block_id, r.html);
          });
        };
        this.handleEvent("bp:block-html", this._onBlockHtml);

        // Re-inject any stashed fleet HTML whenever this hook's element is updated
        // (a WC remount rebuilds the loading-chip holes from data-canvas-blocks).
        this._repaintFleet = () => {
          Object.keys(this._fleetRenders).forEach((id) =>
            this._paintFleet(id, this._fleetRenders[id]),
          );
        };

        // A deferred custom-element upgrade can mount the paint holes AFTER
        // the server reply. Replay the cached HTML as soon as they exist.
        this._onCanvasReady = () => this._repaintFleet();
        this.el.addEventListener("bp-ready", this._onCanvasReady);

        // Request the initial preview once the hook (and its listener above) is
        // mounted, so the live rows land even if the server's setup-time push
        // raced ahead of this handler's registration. Guarded to run-0 so a
        // multi-run paper fires exactly ONE request, not one per wrapper (the
        // wrapper id is slug-namespaced — "paper-canvas-<slug>-run-<i>" — so
        // match the ordinal SUFFIX; "-run-0" can only be the first run: a
        // higher ordinal like "-run-10" doesn't end in "-run-0", and a slug
        // ending in "run-0" still carries its own "-run-<i>" tail after it).
        // The per-block task-query field can push the SAME event with
        // phx-debounce to drive the ~500ms re-resolve on a query edit.
        if (this.el.id.endsWith("-run-0")) {
          this.pushEvent("task-preview-refresh", {});
        }
      },
      updated() {
        if (typeof this._repaintFleet === "function") this._repaintFleet();
      },
      destroyed() {
        this._saveBridgeDestroyed = true;
        this._opsQueue = [];
        this.el.removeEventListener("bp-canvas-ops", this._onCanvasOps);
        this.el.removeEventListener("bp-flush-pending", this._onFlushPending);
        this.el.removeEventListener("bp-ready", this._onCanvasReady);
      }
    };

    // BarkparkFieldBlockBridge — LV↔native-control bridge for the paper
    // editor's field-* LEAF blocks (P2.1). Mounted on the phx-update="ignore"
    // wrapper that holds one native control (checkbox / select / text /
    // textarea / datetime-local / color) per field block. On input/change it
    // coerces the control's value by data-field-type, builds a portable-doc
    // {op:"patch-block", id, patch:{value:…}} op, and pushes it through the
    // SAME `paper-op` handler the rich-text WC uses — the server owns the
    // model, no client state, no echo back into the control.
    Hooks.BarkparkFieldBlockBridge = {
      mounted() {
        const blockId = this.el.dataset.blockId;
        const fieldType = this.el.dataset.fieldType;

        this._pendingSaves = new Set();
        this._retryOp = null;
        const pushOp = (op) => {
          this._retryOp = op;
          const pending = this.pushEvent("paper-op", op)
            .then((reply) => reply?.saved === true)
            .catch(() => false)
            .then((saved) => {
              if (saved && this._retryOp === op) this._retryOp = null;
              return saved;
            })
            .finally(() => this._pendingSaves.delete(pending));
          this._pendingSaves.add(pending);
        };
        const push = (value) => pushOp({
          op: "patch-block",
          id: blockId,
          patch: { value: value }
        });

        // The edit→view boundary dispatches this while the wrapper is still
        // connected. Commit any native text input still inside the 300 ms timer,
        // then contribute every in-flight save reply to the toggle's wait set.
        // Repeated flushes are safe: consuming `_t` before send means the same
        // local edit is never pushed twice, while a newly typed value schedules a
        // fresh timer for the toggle's next drain pass.
        this._onFlushPending = (event) => {
          if (this._t) {
            clearTimeout(this._t);
            this._t = null;
            this._sendPending?.();
          }
          if (!this._pendingSaves.size && this._retryOp) pushOp(this._retryOp);
          if (this._pendingSaves.size) {
            event.detail.waitUntil(
              Promise.all([...this._pendingSaves]).then((results) => results.every(Boolean))
            );
          }
        };
        this.el.addEventListener("bp-flush-pending", this._onFlushPending);

        // PICKER field blocks (field-reference / field-image, P2.2) are driven
        // by a bp-* Web Component (bp-reference-picker / bp-media-picker) that
        // owns its own DOM and emits a bubbling `bp-change` CustomEvent with
        // {detail:{value}} (a string: a referenced doc id, or an image URL) on
        // selection/clear. No native control to read — the value rides on the
        // event. Forward it straight through as a patch-block op.
        if (fieldType === "field-reference" || fieldType === "field-image") {
          this._onChange = (e) => {
            push(e.detail && e.detail.value);
          };
          this.el.addEventListener("bp-change", this._onChange);
          return;
        }

        // IMAGE content blocks (t13 — the locked featured image's picker
        // binding). Unlike the field-* pickers, whose `value` stores the WC's
        // serialized value VERBATIM (JSON asset-refs included), an image block
        // persists a PLAIN URL in `src` (the reader's PdImage contract —
        // compose.ex `image` clause). Read the WC's parsed meta (url + alt) and
        // patch {src, alt}; Remove patches src:"" so the public render skips
        // the block again. `locked`/`role` ride the block untouched — Patch
        // strips them from every patch-block, and a content patch of a locked
        // block is allowed by design (that IS how the featured image binds).
        if (fieldType === "image") {
          this._onChange = (e) => {
            const meta = (e.target && e.target.meta) || {};
            let src = meta.url || "";
            if (!src) {
              // Fallback when meta is unavailable: the emitted value is either
              // a bare URL or the JSON {"url","assetId"} envelope — never
              // persist the envelope into `src`.
              const raw = (e.detail && e.detail.value) || "";
              if (typeof raw === "string" && raw.trim().startsWith("{")) {
                try { src = JSON.parse(raw).url || ""; } catch (_err) { src = ""; }
              } else if (typeof raw === "string") {
                src = raw;
              }
            }
            pushOp({
              op: "patch-block",
              id: blockId,
              patch: { src: src, alt: meta.alt || "" }
            });
          };
          this.el.addEventListener("bp-change", this._onChange);
          return;
        }

        // LEAF field blocks (P2.1) wrap a native control.
        const control = this.el.querySelector("input, select, textarea");
        if (!control) return;
        this._control = control;

        const send = () => {
          let value;
          if (fieldType === "field-boolean") {
            value = control.checked;
          } else {
            value = control.value;
          }
          push(value);
        };
        this._sendPending = send;

        // datetime / color / select / boolean commit on `change`; free-text
        // (string / slug / text) debounce on `input` so we don't flood the
        // server per keystroke.
        const debounced = ["field-string", "field-slug", "field-text"].includes(fieldType);
        if (debounced) {
          this._onInput = () => {
            clearTimeout(this._t);
            this._t = setTimeout(() => {
              this._t = null;
              send();
            }, 300);
          };
          control.addEventListener("input", this._onInput);
        } else {
          this._onChange = send;
          control.addEventListener("change", this._onChange);
        }
      },
      destroyed() {
        clearTimeout(this._t);
        this._t = null;
        this.el.removeEventListener("bp-flush-pending", this._onFlushPending);
        const fieldType = this.el.dataset.fieldType;
        // Picker blocks (field pickers + image content blocks) bind `bp-change`
        // on the wrapper (this.el); leaf blocks bind input/change on the inner
        // native control.
        if (fieldType === "field-reference" || fieldType === "field-image" || fieldType === "image") {
          if (this._onChange) this.el.removeEventListener("bp-change", this._onChange);
          return;
        }
        if (this._control && this._onInput) this._control.removeEventListener("input", this._onInput);
        if (this._control && this._onChange) this._control.removeEventListener("change", this._onChange);
      }
    };

    // BarkparkPaperSortable — drag-handle reorder for the paper block editor
    // (P3.2). Mounted on the editor container. Native HTML5 drag, NO external
    // dependency. CRITICAL: only the per-block GRIP ([data-drag-grip]) is
    // draggable — the block bodies hold contenteditable editors + form inputs,
    // so making the whole block draggable would fight text selection/focus.
    // Each block has draggable="true" on its grip; we resolve the owning
    // [data-edit-block-id] block on dragstart. On drop we compute which block
    // the dragged one landed AFTER (by pointer Y vs each block's midpoint) and
    // push `paper-move-block-to` with {id, after-id} — the server maps it to a
    // single `move-block` op. The server owns the model: we do NOT reorder the
    // DOM optimistically; the {:paper_block,…} delta re-streams the View pane
    // and the assign re-render redraws the Edit list.
    Hooks.BarkparkPaperSortable = {
      mounted() {
        this._dragId = null;

        const blockOf = (node) =>
          node && node.closest ? node.closest("[data-edit-block-id]") : null;

        this._onDragStart = (e) => {
          const grip = e.target.closest && e.target.closest("[data-drag-grip]");
          if (!grip) {
            // Drag did not start on a grip (e.g. a text selection inside the
            // block body) — cancel so the block body is never dragged.
            e.preventDefault();
            return;
          }
          const block = blockOf(grip);
          if (!block) return;
          this._dragId = block.dataset.editBlockId;
          block.classList.add("bp-paper-dragging");
          if (e.dataTransfer) {
            e.dataTransfer.effectAllowed = "move";
            // Firefox requires data to be set for a drag to begin.
            try { e.dataTransfer.setData("text/plain", this._dragId); } catch (_) {}
          }
        };

        this._onDragOver = (e) => {
          if (this._dragId == null) return;
          e.preventDefault();
          if (e.dataTransfer) e.dataTransfer.dropEffect = "move";
        };

        this._onDrop = (e) => {
          if (this._dragId == null) return;
          e.preventDefault();

          // Find the block the pointer is over (or nearest), then decide
          // whether the dragged block lands before or after it by midpoint.
          const blocks = Array.from(this.el.querySelectorAll("[data-edit-block-id]"));
          let afterId = ""; // empty ⇒ drop at the head
          for (const b of blocks) {
            if (b.dataset.editBlockId === this._dragId) continue;
            const rect = b.getBoundingClientRect();
            if (e.clientY > rect.top + rect.height / 2) {
              afterId = b.dataset.editBlockId;
            }
          }

          const draggedId = this._dragId;
          this._clearDrag();
          this.pushEvent("paper-move-block-to", { id: draggedId, "after-id": afterId });
        };

        this._clearDrag = () => {
          const dragging = this.el.querySelector(".bp-paper-dragging");
          if (dragging) dragging.classList.remove("bp-paper-dragging");
          this._dragId = null;
        };
        this._onDragEnd = this._clearDrag;

        this.el.addEventListener("dragstart", this._onDragStart);
        this.el.addEventListener("dragover", this._onDragOver);
        this.el.addEventListener("drop", this._onDrop);
        this.el.addEventListener("dragend", this._onDragEnd);
      },
      destroyed() {
        this.el.removeEventListener("dragstart", this._onDragStart);
        this.el.removeEventListener("dragover", this._onDragOver);
        this.el.removeEventListener("drop", this._onDrop);
        this.el.removeEventListener("dragend", this._onDragEnd);
      }
    };

    // BarkparkPaperContextMenu — right-click block menu for the paper block
    // editor. Mounted on a zero-layout hidden host inside `.bp-paper-editor`
    // (a distinct hook, because BarkparkPaperSortable already owns the editor
    // container and LiveView allows one hook per element). On `contextmenu`
    // over a [data-edit-block-id] block it preventDefault()s and opens a fixed
    // SINGLETON menu appended to <body>; off a block the native browser menu
    // is left alone. Menu items push the SAME server events as the hover
    // toolbar — `paper-move-block` {id, dir:"up"|"down"} and
    // `paper-delete-block` {id} — so there are ZERO server-side changes. Labels
    // are hard-coded and written via textContent (no user content interpolated
    // ⇒ no XSS surface). The window/document dismiss listeners live ONLY while
    // the menu is open (bound on open, dropped on close), so nothing leaks; the
    // singleton element persists across mounts. Right-click never starts an
    // HTML5 drag (that needs a primary-button mousedown + move), so this does
    // not fight the sortable hook.
    const BP_PAPER_CTX_MENU_ID = "bp-paper-context-menu";

    // pdd-t12c: the keyboard twin of a right-click — Shift+F10 (universal) or the
    // dedicated ContextMenu key opens the SAME block menu, so every affordance the
    // mouse has is reachable without one (WCAG 2.1.1; rule 5). Pure predicate.
    function bpIsCtxMenuKey(e) {
      return e.key === "ContextMenu" || (e.shiftKey && e.key === "F10");
    }

    function bpPaperCtxMenuItems(menu) {
      return Array.from(menu.querySelectorAll(".bp-paper-context-menu__item"));
    }

    function bpPaperCtxMenuEl() {
      let menu = document.getElementById(BP_PAPER_CTX_MENU_ID);
      if (menu) return menu;
      menu = document.createElement("div");
      menu.id = BP_PAPER_CTX_MENU_ID;
      menu.className = "bp-paper-context-menu";
      menu.setAttribute("role", "menu");
      menu.setAttribute("aria-label", "Block actions");
      menu.hidden = true;
      // pdd-t2: the calm template note shown (instead of usable move/delete
      // items) when the menu opens on a template-locked block. Hidden for
      // ordinary blocks; static text via textContent (no user content).
      const note = document.createElement("div");
      note.className = "bp-paper-context-menu__note";
      note.setAttribute("role", "presentation");
      note.textContent = "Part of the document template";
      note.hidden = true;
      menu.appendChild(note);
      const items = [
        { action: "move-up", label: "Move up" },
        { action: "move-down", label: "Move down" },
        { sep: true },
        { action: "delete", label: "Delete block", destructive: true },
      ];
      for (const it of items) {
        if (it.sep) {
          const hr = document.createElement("div");
          hr.className = "bp-paper-context-menu__sep";
          hr.setAttribute("role", "separator");
          menu.appendChild(hr);
          continue;
        }
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className =
          "bp-paper-context-menu__item" +
          (it.destructive ? " bp-paper-context-menu__item--destructive" : "");
        btn.setAttribute("role", "menuitem");
        btn.dataset.action = it.action;
        // textContent (never innerHTML) — the labels are static, but this keeps
        // the surface XSS-proof by construction.
        btn.textContent = it.label;
        btn.addEventListener("click", () => bpPaperCtxMenuActivate(it.action));
        menu.appendChild(btn);
      }
      document.body.appendChild(menu);
      return menu;
    }

    function bpPaperCtxMenuOpen(hook, x, y, block) {
      const menu = bpPaperCtxMenuEl();
      const blocks = Array.from(
        (hook._body || document).querySelectorAll("[data-edit-block-id]")
      );
      const idx = blocks.indexOf(block);
      // pdd-t2: a template-locked block can't be moved or deleted; the block
      // BELOW a locked block can't move UP (that would displace the locked
      // block — the server would reject it). Same contract as the hover
      // toolbar: the affordance is disabled, never offered-then-errored.
      const locked = block.dataset.blockLocked === "true";
      const prevLocked =
        idx > 0 && blocks[idx - 1].dataset.blockLocked === "true";
      menu._ctx = {
        pushEvent: (ev, payload) => hook.pushEvent(ev, payload),
        blockId: block.dataset.editBlockId,
        canUp: idx > 0 && !locked && !prevLocked,
        canDown: idx >= 0 && idx < blocks.length - 1 && !locked,
        canDelete: !locked,
        focusBlock: block,
      };
      menu._ownerEl = hook.el;

      const upBtn = menu.querySelector('[data-action="move-up"]');
      const downBtn = menu.querySelector('[data-action="move-down"]');
      const delBtn = menu.querySelector('[data-action="delete"]');
      const note = menu.querySelector(".bp-paper-context-menu__note");
      if (upBtn) upBtn.disabled = !menu._ctx.canUp;
      if (downBtn) downBtn.disabled = !menu._ctx.canDown;
      if (delBtn) delBtn.disabled = !menu._ctx.canDelete;
      if (note) note.hidden = !locked;

      // Show off-screen to measure, then clamp to the viewport (flip left/above
      // when the cursor is near the right/bottom edge).
      menu.hidden = false;
      menu.style.visibility = "hidden";
      menu.style.left = "0px";
      menu.style.top = "0px";
      const rect = menu.getBoundingClientRect();
      const vw = window.innerWidth;
      const vh = window.innerHeight;
      const pad = 6;
      let left = x;
      let top = y;
      if (left + rect.width + pad > vw) left = x - rect.width;
      if (left < pad) left = Math.max(pad, vw - rect.width - pad);
      if (top + rect.height + pad > vh) top = y - rect.height;
      if (top < pad) top = Math.max(pad, vh - rect.height - pad);
      menu.style.left = left + "px";
      menu.style.top = top + "px";
      menu.style.visibility = "";

      const first = bpPaperCtxMenuItems(menu).find((b) => !b.disabled);
      if (first) first.focus();

      bpPaperCtxMenuBindDismiss(menu);
    }

    function bpPaperCtxMenuBindDismiss(menu) {
      if (menu._dismissBound) return;
      menu._dismissBound = true;
      menu._onPointerDown = (e) => {
        if (!menu.contains(e.target)) bpPaperCtxMenuClose();
      };
      menu._onKeyDown = (e) => bpPaperCtxMenuKey(menu, e);
      menu._onScroll = () => bpPaperCtxMenuClose();
      menu._onBlur = () => bpPaperCtxMenuClose();
      document.addEventListener("pointerdown", menu._onPointerDown, true);
      document.addEventListener("keydown", menu._onKeyDown, true);
      window.addEventListener("scroll", menu._onScroll, true);
      window.addEventListener("blur", menu._onBlur);
    }

    function bpPaperCtxMenuClose() {
      const menu = document.getElementById(BP_PAPER_CTX_MENU_ID);
      if (!menu) return;
      menu.hidden = true;
      menu._ctx = null;
      menu._ownerEl = null;
      if (menu._dismissBound) {
        document.removeEventListener("pointerdown", menu._onPointerDown, true);
        document.removeEventListener("keydown", menu._onKeyDown, true);
        window.removeEventListener("scroll", menu._onScroll, true);
        window.removeEventListener("blur", menu._onBlur);
        menu._dismissBound = false;
      }
    }

    function bpPaperCtxMenuKey(menu, e) {
      if (menu.hidden) return;
      if (e.key === "Tab") {
        bpPaperCtxMenuClose();
        return;
      }
      if (e.key === "Escape") {
        e.preventDefault();
        const focusBack = menu._ctx && menu._ctx.focusBlock;
        bpPaperCtxMenuClose();
        if (focusBack && document.contains(focusBack)) {
          if (!focusBack.hasAttribute("tabindex"))
            focusBack.setAttribute("tabindex", "-1");
          focusBack.focus();
        }
        return;
      }
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        // Only steer the menu while focus is inside it; otherwise the open menu
        // would swallow document-wide arrow keys — close and let them through.
        if (!menu.contains(document.activeElement)) {
          bpPaperCtxMenuClose();
          return;
        }
        e.preventDefault();
        const items = bpPaperCtxMenuItems(menu).filter((b) => !b.disabled);
        if (!items.length) return;
        let i = items.indexOf(document.activeElement);
        const delta = e.key === "ArrowDown" ? 1 : -1;
        if (i === -1) i = delta > 0 ? 0 : items.length - 1;
        else i = (i + delta + items.length) % items.length;
        items[i].focus();
      }
      // Enter/Space are handled natively by the focused <button> (→ click →
      // bpPaperCtxMenuActivate), so we do not intercept them here.
    }

    function bpPaperCtxMenuActivate(action) {
      const menu = document.getElementById(BP_PAPER_CTX_MENU_ID);
      if (!menu || !menu._ctx) return;
      const ctx = menu._ctx;
      const focusBack = menu._ctx && menu._ctx.focusBlock;
      // Close first (drops the dismiss listeners) so activation and dismissal
      // never race, then push the same events the hover toolbar pushes.
      bpPaperCtxMenuClose();
      if (action === "move-up")
        ctx.pushEvent("paper-move-block", { id: ctx.blockId, dir: "up" });
      else if (action === "move-down")
        ctx.pushEvent("paper-move-block", { id: ctx.blockId, dir: "down" });
      else if (action === "delete")
        ctx.pushEvent("paper-delete-block", { id: ctx.blockId });
      // Restore focus to the block (same dance as the Escape path) so keyboard
      // users aren't stranded — skip for delete, whose block the patch removes.
      if (action !== "delete" && focusBack && document.contains(focusBack)) {
        if (!focusBack.hasAttribute("tabindex"))
          focusBack.setAttribute("tabindex", "-1");
        focusBack.focus();
      }
    }

    Hooks.BarkparkPaperContextMenu = {
      mounted() {
        // The host is a hidden child of the editor; resolve the editor body it
        // lives in so `contextmenu` is scoped to this editor's blocks.
        this._body =
          this.el.closest(".bp-paper-editor") || this.el.parentElement || this.el;

        this._onContextMenu = (e) => {
          // Inside editable content (TipTap contenteditable, any block-edit
          // input/textarea/select), the native menu wins — hijacking it kills
          // paste/spellcheck. The block menu still fires on block chrome.
          const t = e.target;
          if (
            t.isContentEditable ||
            (t.closest &&
              t.closest(
                'input, textarea, select, [contenteditable="true"], .bp-paper-editor-body',
              ))
          )
            return;
          const block =
            e.target.closest && e.target.closest("[data-edit-block-id]");
          if (!block || !this._body.contains(block)) return; // off a block ⇒ native menu
          e.preventDefault();
          bpPaperCtxMenuOpen(this, e.clientX, e.clientY, block);
        };
        this._body.addEventListener("contextmenu", this._onContextMenu);

        // pdd-t12c: keyboard parity — Shift+F10 / ContextMenu key opens the block
        // menu at the focused block, so keyboard users get the move/delete (or the
        // locked-template note) the right-click menu ships. Same guards as the
        // pointer path: inside editable text / a form control the native menu wins
        // (hijacking would kill paste/spellcheck); off a block, nothing. Anchor to
        // document.activeElement (where the key was pressed) → its owning block →
        // its rect, so the menu lands next to the block, not the viewport origin.
        this._onKeyDown = (e) => {
          if (!bpIsCtxMenuKey(e)) return;
          const active = document.activeElement;
          const t = active && active !== document.body ? active : e.target;
          if (!t || typeof t.closest !== "function") return;
          if (
            t.isContentEditable ||
            t.closest(
              'input, textarea, select, [contenteditable="true"], .bp-paper-editor-body',
            )
          )
            return; // canvas atoms + editable fields own their own keys
          const block = t.closest("[data-edit-block-id]");
          if (!block || !this._body.contains(block)) return;
          e.preventDefault();
          const r = block.getBoundingClientRect();
          bpPaperCtxMenuOpen(this, r.left + 12, r.top + 12, block);
        };
        this._body.addEventListener("keydown", this._onKeyDown);
      },
      destroyed() {
        if (this._body && this._onContextMenu)
          this._body.removeEventListener("contextmenu", this._onContextMenu);
        if (this._body && this._onKeyDown)
          this._body.removeEventListener("keydown", this._onKeyDown);
        // If this instance owns the open menu, close it so no window/document
        // listeners are stranded when the editor is torn down.
        const menu = document.getElementById(BP_PAPER_CTX_MENU_ID);
        if (menu && menu._ownerEl === this.el) bpPaperCtxMenuClose();
      },
    };

    // BarkparkFieldBridge — generic LV↔WC bridge (Task #11 WI4).
    // Mounted on a wrapper div containing a hidden <input> + a bp-*
    // custom element. Listens for bubbled `bp-change` events, mirrors
    // detail.value into the hidden input identified by the WC's
    // data-bridge-target, and dispatches a synthetic `input` event so
    // Phoenix's existing phx-change="autosave" debounce + form
    // serialise + push round-trip fires exactly as for native inputs.
    // Reusable for future bp-media-picker / bp-reference-picker /
    // bp-document-preview / bp-json-inspector — no per-widget hook.
    Hooks.BarkparkFieldBridge = {
      mounted() {
        this._dirty = false;
        this._formVersion = 0;
        this._pendingSaves = new Set();
        this._paperForm = this.el.matches("form[data-paper-field-flush]")
          ? this.el
          : this.el.closest("form[data-paper-field-flush]");
        this._ownsPaperForm = this._paperForm === this.el;
        this._pendingRequests = new Map();

        const trackFormChange = () => {
          this._formVersion += 1;
          this._dirty = true;
        };
        if (this._ownsPaperForm) {
          this._onFormInput = trackFormChange;
          this._onFormChange = trackFormChange;
          this.el.addEventListener("input", this._onFormInput);
          this.el.addEventListener("change", this._onFormChange);
          this._onPaperFieldSaveResult = (payload) => {
            const request = payload && this._pendingRequests.get(payload.request_id);
            if (request) request.finish(payload.saved === true);
          };
          this._paperSaveResultRef = this.handleEvent(
            "bp:paper-field-save-result",
            this._onPaperFieldSaveResult,
          );
          this._onArrayOpClick = (event) => {
            const button = event.target.closest?.('[phx-click="inner-array-op"]');
            if (!button || !this.el.contains(button) || button.disabled) return;

            // In reader edit mode, own the structural event so its parent write
            // participates in the same correlated barrier as field changes.
            // Studio has no Edit/View barrier, so its ordinary LiveView click
            // binding remains untouched.
            const toggle = this.el.closest("main")?.querySelector(
              '[phx-hook="BarkparkPaperEditToggle"]',
            );
            if (!toggle) return;

            event.preventDefault();
            event.stopImmediatePropagation();
            this._formVersion += 1;
            const version = this._formVersion;
            this._dirty = false;
            const params = { action: button.getAttribute("phx-value-action") };
            const index = button.getAttribute("phx-value-index");
            if (index != null) params.index = index;
            this._pushCorrelated("inner-array-op", params, version);
          };
          this.el.addEventListener("click", this._onArrayOpClick, true);
        }

        this._trackSave = (save, version) => {
          const pending = save
            .then((saved) => {
              if (!saved && this._formVersion === version) this._dirty = true;
              return saved;
            })
            .finally(() => this._pendingSaves.delete(pending));
          this._pendingSaves.add(pending);
          return pending;
        };

        this._pushCorrelated = (event, params, version) => {
          window.__bpPaperFieldFlushSeq = (window.__bpPaperFieldFlushSeq || 0) + 1;
          const requestId = `bp-field-${Date.now()}-${window.__bpPaperFieldFlushSeq}`;
          params.request_id = requestId;
          const target = this.el.getAttribute("phx-target") || this.el;
          const save = new Promise((resolve) => {
            let finished = false;
            const finish = (saved) => {
              if (finished) return;
              finished = true;
              clearTimeout(timeout);
              this._pendingRequests.delete(requestId);
              resolve(saved === true);
            };
            const timeout = setTimeout(() => finish(false), 10000);
            this._pendingRequests.set(requestId, { finish });
            try {
              Promise.resolve(this.pushEventTo(target, event, params))
                .then((results) => {
                  if (!Array.isArray(results) || results.length === 0 ||
                      results.some((result) => result.status !== "fulfilled")) {
                    finish(false);
                  }
                })
                .catch(() => finish(false));
            } catch (_err) {
              finish(false);
            }
          });
          return this._trackSave(save, version);
        };

        this._pushForm = () => {
          const input = this._bridgeInput;
          const form = this._ownsPaperForm ? this._paperForm : input && input.form;
          const event = form &&
            ((input && input.getAttribute("phx-change")) || form.getAttribute("phx-change"));
          if (!form || !event) return null;

          const params = Object.fromEntries(new FormData(form));
          const version = this._formVersion;
          const target = (input && input.getAttribute("phx-target")) ||
            form.getAttribute("phx-target") || form;

          let save;
          if (this._ownsPaperForm) {
            return this._pushCorrelated("inner-flush", { values: params }, version);
          } else {
            save = this.pushEventTo(target, event, params)
              .then((results) => results.length > 0 && results.every((result) =>
                result.status === "fulfilled" && result.value?.reply?.saved !== false
              ))
              .catch(() => false);
          }

          return this._trackSave(save, version);
        };
        this._on = (e) => {
          const nearestBridge = e.target.closest &&
            e.target.closest('[phx-hook="BarkparkFieldBridge"]');
          if (nearestBridge && nearestBridge !== this.el) return;
          const targetId = e.target.dataset.bridgeTarget;
          if (!targetId) return;
          const input = document.getElementById(targetId);
          if (!input) return;
          this._bridgeInput = input;
          this._formVersion += 1;
          this._dirty = true;
          input.value = e.detail.value;
          input.dispatchEvent(new Event("input", { bubbles: true }));
        };
        this.el.addEventListener("bp-change", this._on);
        this._onFlushPending = (event) => {
          // A nested picker bridge mirrors its hidden input; the hook mounted
          // on the surrounding PaperFieldBlock form owns the correlated save.
          if (this._paperForm && !this._ownsPaperForm) return;
          if (this._dirty) {
            this._dirty = false;
            this._pushForm();
          }
          if (this._pendingSaves.size) {
            event.detail.waitUntil(Promise.all([...this._pendingSaves]).then((results) => results.every(Boolean)));
          }
        };
        this.el.addEventListener("bp-flush-pending", this._onFlushPending);
      },
      destroyed() {
        this.el.removeEventListener("bp-change", this._on);
        this.el.removeEventListener("bp-flush-pending", this._onFlushPending);
        if (this._onFormInput) this.el.removeEventListener("input", this._onFormInput);
        if (this._onFormChange) this.el.removeEventListener("change", this._onFormChange);
        if (this._onArrayOpClick) this.el.removeEventListener("click", this._onArrayOpClick, true);
        if (this._paperSaveResultRef != null && typeof this.removeHandleEvent === "function") {
          this.removeHandleEvent(this._paperSaveResultRef);
        }
        this._pendingRequests.forEach((request) => request.finish(false));
      }
    };


  window.BarkparkPaperEditorHooks = Hooks;
})();
