import { DEBOUNCE_MS } from "./contract.js";
import {
  buildPatchBlockOp,
  buildCardBodyOp,
  tableProjection,
  tableTiptapDocSupported,
  buildTableCellsOp,
  tableProjectionMatchesCells,
  tableProjectionMatchesAction,
} from "./convert.js";

export const paperEditorRuntimeMethods = Object.freeze({
  // Synchronously emit the debounced patch, if one is pending. Returns true only
  // when this call dispatched bp-op; repeated calls are therefore safe while the
  // server acknowledgement is still in flight.
  flushPendingChanges() {
    if (!this._editor || !this._editable || !this._debounceTimer) return false;
    clearTimeout(this._debounceTimer);
    this._debounceTimer = null;
    return this._emitOp();
  },

  // 1.22.0: focus the editing surface where its selection already is, so a host
  // no longer focuses [contenteditable] inside the element.
  focusSelection() {
    const view = this._editor?.view;
    if (!view) return false;
    view.focus();
    return view.hasFocus();
  },

  // Synchronous host seam for navigation / beforeunload guards. The editor is
  // dirty as soon as its debounce exists, before bp-op has been dispatched.
  hasPendingChanges() {
    return Boolean(this._debounceTimer || this._tableSettlement);
  },

  _filterTableTransaction(transaction) {
    if (this._discardTableDraft === true) {
      this._tableAcceptedUpdate = false;
      return true;
    }
    const supported = tableTiptapDocSupported(transaction.doc.toJSON(), this._sourceBlock);
    if (transaction.docChanged) {
      this._tableAcceptedUpdate = supported;
      if (supported) this._clearTableEditRefusal();
      else this._reportTableEditRefusal();
    }
    return supported;
  },

  _reportTableEditRefusal() {
    if (!this._tableEditStatus || this._tableEditStatus.dataset.state === "refused") return;
    this._tableEditStatus.dataset.state = "refused";
    this._tableEditStatus.hidden = false;
    this._tableEditStatus.textContent =
      "That change would remove protected Table content. Keep this cell as one non-empty text run.";
  },

  _clearTableEditRefusal() {
    if (!this._tableEditStatus || this._tableEditStatus.dataset.state !== "refused") return;
    this._tableEditStatus.dataset.state = "";
    this._tableEditStatus.hidden = true;
    this._tableEditStatus.textContent = "";
  },

  _installTableProjectionDoc(doc) {
    if (!this._editor) return false;
    if (JSON.stringify(this._editor.getJSON()) === JSON.stringify(doc)) return true;
    const target = this._editor.schema.nodeFromJSON(doc);
    const sameContent = (left, right) => {
      if (left.type !== right.type || left.text !== right.text ||
          JSON.stringify(left.marks) !== JSON.stringify(right.marks) ||
          left.childCount !== right.childCount) return false;
      for (let index = 0; index < left.childCount; index++) {
        if (!sameContent(left.child(index), right.child(index))) return false;
      }
      return true;
    };
    if (sameContent(this._editor.state.doc, target)) {
      const transaction = this._editor.state.tr;
      this._editor.state.doc.descendants((node, position) => {
        if (node.isText) return;
        const targetNode = target.nodeAt(position);
        if (targetNode && JSON.stringify(node.attrs) !== JSON.stringify(targetNode.attrs)) {
          transaction.setNodeMarkup(position, undefined, targetNode.attrs, node.marks);
        }
      });
      if (transaction.docChanged) {
        transaction.setMeta("addToHistory", false);
        transaction.setMeta("preventUpdate", true);
        this._editor.view.dispatch(transaction);
      }
      return true;
    }
    this._editor.commands.setContent(doc, { emitUpdate: false });
    return true;
  },

  // Explicit conflict resolution seam. The host calls this only after the user
  // chooses "Use latest"; unlike a normal server echo it intentionally discards
  // the pending local debounce before installing the authoritative block.
  resolveConflictWithServerBlock(block) {
    if (this._editorMode === "table" && this._sourceBlock?.id != null &&
        block?.id != null && block.id !== this._sourceBlock.id) return false;
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = null;
    this._cardBodyDraftJSON = null;
    this._cardBodyAwaitingContents = [];
    this._cardBodyDirtyToken = null;
    this._tableDraftJSON = null;
    this._tableDirtyToken = null;
    this._tableAwaitingCells = [];
    this._tablePendingAction = null;
    this._tableStructureAwaiting = null;
    this._tableRefocusNewRow = false;
    this._settleTableLifecycle(false);
    this._discardCardBodyDraft = true;
    this._discardTableDraft = true;
    try {
      this.block = block;
    } finally {
      this._discardCardBodyDraft = false;
      this._discardTableDraft = false;
    }
    return true;
  },

  // Read the initial block from the `block` JS property (object) first, then
  // fall back to a `data-block` attribute holding a JSON string.
  _readBlock() {
    if (this._blockProp && typeof this._blockProp === "object") {
      return this._blockProp;
    }
    const raw = this.getAttribute("data-block") || this.dataset.block;
    if (raw) {
      try {
        return JSON.parse(raw);
      } catch (_e) {
        // Surface bad inbound data to the host (additive); the silent default
        // below is preserved so a malformed data-block never blocks the editor.
        this.dispatchEvent(
          new CustomEvent("bp-error", {
            detail: { error: _e.message, raw },
            bubbles: true,
            composed: true,
          }),
        );
        // fall through to a default empty paragraph
      }
    }
    return { id: null, type: "paragraph", content: [] };
  },

  _scheduleEmit() {
    if (!this._editable) return; // read mode emits no patch-block op
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = setTimeout(() => {
      this._debounceTimer = null;
      this._emitOp();
    }, DEBOUNCE_MS);
  },

  _emitOp() {
    if (!this._editor || this._blockId == null) return false;
    const json = this._editor.getJSON();
    let op;
    if (this._editorMode === "card-body") {
      const draftJSON = JSON.parse(JSON.stringify(json));
      const initial = buildCardBodyOp(
        draftJSON,
        this._sourceBlock,
        this._cardBodyAwaitingContents.length > 0,
      );
      if (!initial) {
        const settledToken = this._cardBodyDraftJSON ? this._cardBodyDirtyToken : null;
        this._cardBodyDraftJSON = null;
        if (settledToken != null) {
          this.dispatchEvent(new CustomEvent("bp-noop", {
            detail: { token: settledToken },
            bubbles: true,
            composed: true,
          }));
          this._cardBodyDirtyToken = null;
        }
        return false;
      }
      // This typed body-only operation is resolved against the authoritative
      // Card at the server mutation boundary. It cannot overwrite a concurrent
      // title/media/action/unknown-slot change with a stale whole-slots map.
      op = initial;
      this._cardBodyAwaitingContents.push(JSON.parse(JSON.stringify(initial.content)));
    } else if (this._editorMode === "table") {
      const forcedCells = this._tableAwaitingCells.flatMap((entry) => entry);
      const initial = buildTableCellsOp(json, this._sourceBlock, forcedCells);
      if (!initial) {
        const settledToken = this._tableDraftJSON ? this._tableDirtyToken : null;
        this._tableDraftJSON = null;
        if (settledToken != null) {
          this.dispatchEvent(new CustomEvent("bp-noop", {
            detail: { token: settledToken },
            bubbles: true,
            composed: true,
          }));
          this._tableDirtyToken = null;
        }
        return false;
      }
      op = initial;
      this._tableAwaitingCells.push(JSON.parse(JSON.stringify(initial.cells)));
    } else {
      op = buildPatchBlockOp(json, this._blockId, this._blockType);
    }
    if (!op) return false;
    this.dispatchEvent(
      new CustomEvent("bp-op", {
        detail: op,
        bubbles: true,
        composed: true,
      }),
    );
    return true;
  },

  _requestTableStructure(action) {
    if (this._editorMode !== "table" || !this._editor || !this._editable ||
        this._tableSourceError || this._tablePendingAction || this._tableStructureAwaiting ||
        !this._validTableAction(action)) return false;
    // Tab past the last cell asks for a row while the author is typing in the table.
    // The editor goes read-only until the server echoes the new shape, which drops
    // focus; without a caret back in the new row the next keystrokes went nowhere.
    this._tableRefocusNewRow = action === "add-row" && this._editor.view.hasFocus();
    this._ensureTableSettlement();
    this.flushPendingChanges();
    this._tablePendingAction = action;
    if (this._tableAwaitingCells.length === 0) this._emitTableStructure();
    return true;
  },

  _emitTableStructure() {
    if (!this._tablePendingAction || !this._sourceBlock) return false;
    const action = this._tablePendingAction;
    const projection = tableProjection(this._sourceBlock);
    if (!projection.editable || !this._validTableAction(action)) return false;
    const op = {
      op: "patch-table-structure",
      id: this._sourceBlock.id,
      shape: JSON.parse(JSON.stringify(projection.shape)),
      action,
    };
    this._tablePendingAction = null;
    this._tableStructureAwaiting = JSON.parse(JSON.stringify(op));
    this._tableStructureAwaiting.requestId = null;
    this._tableStructureAwaiting.saved = false;
    this._tableStructureAwaiting.echo = null;
    this._editor.setEditable(false, false);
    this.dispatchEvent(new CustomEvent("bp-op", {
      detail: op,
      bubbles: true,
      composed: true,
    }));
    return true;
  },

  waitForTableSettlement() {
    return this._tableSettlement?.promise || null;
  },

  trackTableMutation(op, requestId) {
    if (op?.op !== "patch-table-structure" || !this._tableStructureAwaiting ||
        this._tableStructureAwaiting.op !== op.op ||
        this._tableStructureAwaiting.id !== op.id ||
        this._tableStructureAwaiting.action !== op.action ||
        JSON.stringify(this._tableStructureAwaiting.shape) !== JSON.stringify(op.shape) ||
        typeof requestId !== "string" || requestId === "") return false;
    this._tableStructureAwaiting.requestId = requestId;
    return true;
  },

  tableMutationResult(op, saved, result) {
    const awaiting = this._tableStructureAwaiting;
    if (op?.op !== "patch-table-structure" || !awaiting ||
        result?.request_id !== awaiting.requestId) return false;
    if (saved !== true) return false;
    awaiting.saved = true;
    if (awaiting.echo) this._acceptTableStructureEcho();
    return true;
  },

  applyTableProjection(value, metadata = {}) {
    if (this._sourceBlock?.id != null && value?.id != null &&
        value.id !== this._sourceBlock.id) return false;
    const awaiting = this._tableStructureAwaiting;
    if (awaiting) {
      if (metadata.requestId !== awaiting.requestId ||
          !tableProjectionMatchesAction(this._sourceBlock, value, awaiting.action)) {
        return false;
      }
      this._blockProp = value;
      awaiting.echo = { value, metadata };
      if (awaiting.saved) this._acceptTableStructureEcho();
      return true;
    }
    this._blockProp = value;
    return this._acceptTableProjection(value);
  },

  _acceptTableStructureEcho() {
    const echo = this._tableStructureAwaiting?.echo;
    if (!echo) return false;
    this._tableStructureAwaiting = null;
    this._acceptTableProjection(echo.value);
    this._settleTableLifecycle(true);
    if (this._tableRefocusNewRow) this._focusLastRowFirstCell();
    this._tableRefocusNewRow = false;
    return true;
  },

  _focusLastRowFirstCell() {
    const editor = this._editor;
    if (!editor || editor.isDestroyed || !editor.isEditable) return false;
    let rowPos = null;
    editor.state.doc.descendants((node, pos) => {
      if (node.type.name === "bpTableRow") rowPos = pos;
      return node.type.name !== "bpTableRow";
    });
    if (rowPos == null) return false;
    // rowPos + 1 is the first cell; + 2 is inside it.
    editor.commands.setTextSelection(rowPos + 2);
    // Synchronously: TipTap's focus() would wait a frame, and a fast typist's
    // next key would land outside the table.
    editor.view.focus();
    return true;
  },

  _ensureTableSettlement() {
    if (this._tableSettlement) return this._tableSettlement.promise;
    let resolve;
    const promise = new Promise((done) => { resolve = done; });
    this._tableSettlement = { promise, resolve };
    return promise;
  },

  _settleTableLifecycle(result) {
    const settlement = this._tableSettlement;
    this._tableSettlement = null;
    settlement?.resolve(result);
  },

  _validTableAction(action) {
    if (typeof action !== "string") return false;
    const projection = tableProjection(this._sourceBlock);
    if (!projection.editable) return false;
    const rows = projection.rows.length;
    const columns = projection.rows[0].length;
    if (action === "add-row" || action === "add-column") return true;
    if (action === "add-header") return projection.head == null;
    if (action === "remove-header") return projection.head != null;
    const match = /^(remove|up|down)-row:(0|[1-9]\d*)$/.exec(action);
    if (match) {
      const index = Number(match[2]);
      if (!Number.isSafeInteger(index) || index >= rows) return false;
      return match[1] === "remove" ? rows > 1
        : match[1] === "up" ? index > 0 : index + 1 < rows;
    }
    const columnMatch = /^(remove|left|right)-column:(0|[1-9]\d*)$/.exec(action);
    if (!columnMatch) return false;
    const index = Number(columnMatch[2]);
    if (!Number.isSafeInteger(index) || index >= columns) return false;
    return columnMatch[1] === "remove" ? columns > 1
      : columnMatch[1] === "left" ? index > 0 : index + 1 < columns;
  },

  _acceptTableProjection(value) {
    const projection = tableProjection(value);
    this._tableEditable = projection.editable;
    this._editable = this.getAttribute("editable") !== "false" && projection.editable;
    if (this._editor.isEditable !== this._editable) {
      this._editor.setEditable(this._editable, false);
    }
    if (!projection.editable) {
      if (!this._tableSourceError) {
        this._tableSourceError = true;
        this.dispatchEvent(new CustomEvent("bp-error", {
          detail: {
            code: "table_source_unsupported",
            error: "Table changed to an unsupported shape. Your draft is retained; resolve the server version before continuing.",
          },
          bubbles: true,
          composed: true,
        }));
      }
      if (this._discardTableDraft) {
        this._sourceBlock = value && typeof value === "object"
          ? JSON.parse(JSON.stringify(value)) : value;
        this._installTableProjectionDoc(projection.doc);
      }
      return false;
    }
    if (this._tableDraftJSON &&
        !tableTiptapDocSupported(this._tableDraftJSON, value)) {
      this._tableEditable = false;
      this._editable = false;
      this._editor.setEditable(false, false);
      this._blockId = value.id;
      this._blockType = "table";
      this._sourceBlock = JSON.parse(JSON.stringify(value));
      if (!this._tableSourceError) {
        this._tableSourceError = true;
        this.dispatchEvent(new CustomEvent("bp-error", {
          detail: {
            code: "table_draft_incompatible",
            error: "Table metadata changed while you were editing. Your draft is retained; review the server version before continuing.",
          },
          bubbles: true,
          composed: true,
        }));
      }
      return false;
    }
    this._tableSourceError = false;
    this._blockId = value.id;
    this._blockType = "table";
    this._sourceBlock = JSON.parse(JSON.stringify(value));
    if (this._tableAwaitingCells.length > 0 &&
        tableProjectionMatchesCells(value, this._tableAwaitingCells[0])) {
      this._tableAwaitingCells.shift();
    }
    const forcedCells = this._tableAwaitingCells.flatMap((entry) => entry);
    const preservesDraft = this._tableDraftJSON &&
      (buildTableCellsOp(this._tableDraftJSON, value, forcedCells) !== null ||
        this._tableAwaitingCells.length > 0);
    if (!preservesDraft) {
      this._tableDraftJSON = null;
      this._tableDirtyToken = null;
      this._installTableProjectionDoc(projection.doc);
    }
    if (this._tablePendingAction && this._tableAwaitingCells.length === 0) {
      this._emitTableStructure();
    }
    return true;
  },
});

