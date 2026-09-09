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

  // Native on-page text fields keep browser selection/undo and the ordinary
  // form save coordinator. Manage height and the citation's first-line prefix.
  Hooks.BarkparkPaperAutoSize = {
    mounted() {
      this._fit = () => {
        if (this._disposed || !this.el.isConnected) return;
        if (this.el.parentElement?.matches(".bp-blockquote__cite")) {
          // The reader's dash occupies only the first line. Measure its actual
          // glyph width so wrapped native text keeps the same available space.
          const prefix = window.getComputedStyle(this.el.parentElement, "::before");
          const width = Number.parseFloat(prefix.width);
          if (Number.isFinite(width)) this.el.style.textIndent = `${width}px`;
        }
        this.el.style.height = "0px";
        let height = this.el.scrollHeight;
        if (this.el.classList.contains("bp-paper-inline-text")) {
          const style = window.getComputedStyle(this.el);
          const lineHeight = Number.parseFloat(style.lineHeight);
          const plain = ["paddingTop", "paddingBottom", "borderTopWidth", "borderBottomWidth"]
            .every((property) => Number.parseFloat(style[property]) === 0);
          // scrollHeight is integer-rounded, unlike the reader's line boxes.
          // Only correct that rounding for plain fields with a known line height;
          // preserve the measured fallback for padding, normal line height or overflow.
          const exact = Math.max(1, Math.round(height / lineHeight)) * lineHeight;
          if (plain && Number.isFinite(exact) && lineHeight > 1 && Math.abs(exact - height) < 1) {
            height = exact;
          }
        }
        this.el.style.height = `${height}px`;
      };
      this._fit();
      this.el.addEventListener("input", this._fit);
      this._width = null;
      if (window.ResizeObserver) {
        this._resize = new window.ResizeObserver(([entry]) => {
          if (!entry || entry.contentRect.width === this._width) return;
          this._width = entry.contentRect.width;
          this._fit();
        });
        this._resize.observe(this.el.parentElement);
      } else {
        window.addEventListener("resize", this._fit);
      }
      document.fonts?.ready.then(this._fit);
    },
    updated() { this._fit(); },
    destroyed() {
      this._disposed = true;
      this.el.removeEventListener("input", this._fit);
      this._resize?.disconnect();
      window.removeEventListener("resize", this._fit);
    },
  };
  const PAPER_OP_RETRY_TTL_MS = 60 * 60 * 1000;
  const PAPER_CONTEXTUAL_HISTORY_LIMIT = 100;
  const PAPER_CANVAS_LEASES = Symbol("bpPaperCanvasLeases");
  const PAPER_CANVAS_LEASE_PENDING = Symbol("bpPaperCanvasLeasePending");
  const PAPER_CANVAS_LEASE_OVERFLOW = Symbol("bpPaperCanvasLeaseOverflow");
  const PAPER_CANVAS_LEASE_MAX_COUNT = 64;
  const PAPER_CANVAS_LEASE_MAX_LENGTH = 2048;
  const PAPER_CANVAS_LEASE_MAX_TOTAL_LENGTH = 32768;
  const PAPER_FLUSH_TARGETS =
    '[phx-hook="BarkparkPaperCanvas"], [phx-hook="BarkparkPaperEditor"], ' +
    '[phx-hook="BarkparkFieldBlockBridge"], [phx-hook="BarkparkFieldBridge"], ' +
    '[phx-hook="BarkparkFigureImageBridge"]';
  const PAPER_STRUCTURAL_EVENTS = new Set([
    "paper-delete-block",
    "paper-materialize-slot",
    "paper-move-block",
    "paper-move-block-to",
    "paper-unbind-property",
  ]);
  const PAPER_STRUCTURAL_SUBMITS = new Set([
    "paper-add-block",
    "paper-add-property",
    "paper-edit-block",
  ]);
  const PAPER_POSITIONAL_COLLECTION_PARAM =
    /^(note|tab|param|ref|bar|toc|criterion|gauge|panel|step|question)-(?:count|action|\d+-)/;
  const PAPER_POSITIONAL_COLLECTION_ACTION_PARAM =
    /^(?:(?:note|tab|param|ref|bar|toc|criterion|gauge|panel|step|question|section|column|terminal)-action|option-action)$/;
  const PAPER_LINK_REFERENCE_COPY_KEYS = [
    "block_id", "paper-link-ref-field", "paper-link-ref-guard",
    "paper-link-ref-index", "paper-link-ref-slug", "paper-link-ref-value",
  ];
  const PAPER_TRANSIENT_SAVE_STATUSES = new Set([
    "", "Auto-saved", "✓ Auto-saved", "Saving…",
    "Unsaved changes — fix invalid fields.",
    "Save paused — review required.",
    "Save paused — retry required.",
  ]);
  const paperExitCoordinators = new WeakMap();

  function bpPaperLinkReferenceCopySource(value) {
    if (!value || typeof value !== "object") return null;
    const keys = Object.keys(value).sort();
    if (keys.length !== PAPER_LINK_REFERENCE_COPY_KEYS.length ||
        keys.some((key, index) => key !== PAPER_LINK_REFERENCE_COPY_KEYS[index]) ||
        PAPER_LINK_REFERENCE_COPY_KEYS.some((key) => typeof value[key] !== "string") ||
        !["title", "description"].includes(value["paper-link-ref-field"])) return null;
    return value;
  }

  function bpPaperLinkReferenceCopyForm(form) {
    if (!form?.matches?.(".bp-paper-edit-form[phx-change]")) return null;
    const entries = [...new FormData(form)];
    if (entries.length !== PAPER_LINK_REFERENCE_COPY_KEYS.length ||
        entries.some(([_key, value]) => typeof value !== "string")) return null;
    const value = Object.fromEntries(entries);
    if (Object.keys(value).length !== entries.length) return null;
    return bpPaperLinkReferenceCopySource(value);
  }

  function bpPaperCanvasLeaseSet(value) {
    if (!Array.isArray(value)) return { leases: [], valid: false };
    const leases = [];
    const seen = new Set();
    let totalLength = 0;
    for (const lease of value) {
      if (typeof lease !== "string" || lease.length === 0 ||
          lease.length > PAPER_CANVAS_LEASE_MAX_LENGTH) {
        return { leases: [], valid: false };
      }
      if (seen.has(lease)) continue;
      if (leases.length >= PAPER_CANVAS_LEASE_MAX_COUNT ||
          totalLength + lease.length > PAPER_CANVAS_LEASE_MAX_TOTAL_LENGTH) {
        return { leases: [], valid: false };
      }
      leases.push(lease);
      seen.add(lease);
      totalLength += lease.length;
    }
    return { leases, valid: true };
  }

  function bpPaperOpsInsertRetainedBoundary(ops) {
    return Array.isArray(ops) && ops.some((op) =>
      (op?.op === "insert-after" || op?.op === "append-block" || op?.op === "replace-block") &&
      (op?.block?.type === "table" || op?.block?.type === "section"));
  }

  // Collection forms use positional field names. After a reorder LiveView can
  // retain the focused button at its old index, now belonging to another row.
  // Restore the operated row only after acknowledgement, without stealing focus
  // from a user who has moved elsewhere while the request was in flight.
  function bpPaperCollectionFocus(form, submitter) {
    if (submitter?.name === "column-action") {
      const value = submitter.value || "";
      const addTrack = value === "add-column";
      const removeTrack = /^remove-column:(0|[1-9]\d*)$/.exec(value);
      if (addTrack || removeTrack) {
        if (document.activeElement !== submitter) return () => {};
        const columnCount = Number(form.elements.namedItem("column-count")?.value);
        if (!Number.isSafeInteger(columnCount) || columnCount < 0) return () => {};
        const beforeColumns = [];
        for (let columnIndex = 0; columnIndex < columnCount; columnIndex += 1) {
          const childCount = Number(
            form.elements.namedItem(`column-${columnIndex}-child-count`)?.value,
          );
          if (!Number.isSafeInteger(childCount) || childCount < 0) return () => {};
          const ids = Array.from({ length: childCount }, (_unused, childIndex) =>
            form.elements.namedItem(`column-${columnIndex}-child-${childIndex}-id`)?.value);
          if (ids.some((id) => typeof id !== "string" || id === "") ||
              new Set(ids).size !== ids.length) return () => {};
          beforeColumns.push(ids);
        }
        const removedIndex = removeTrack ? Number(removeTrack[1]) : null;
        if (removeTrack &&
            (columnCount < 2 || removedIndex !== columnCount - 1 ||
              beforeColumns[removedIndex].length !== 0)) return () => {};
        const nextColumnCount = columnCount + (addTrack ? 1 : -1);
        return () => {
          if (!form.isConnected ||
              (document.activeElement !== submitter &&
                !(document.activeElement === document.body && !submitter.isConnected)) ||
              Number(form.elements.namedItem("column-count")?.value) !== nextColumnCount) return;
          for (let columnIndex = 0; columnIndex < nextColumnCount; columnIndex += 1) {
            const childCount = Number(
              form.elements.namedItem(`column-${columnIndex}-child-count`)?.value,
            );
            if (!Number.isSafeInteger(childCount) || childCount < 0) return;
            const ids = Array.from({ length: childCount }, (_unused, childIndex) =>
              form.elements.namedItem(`column-${columnIndex}-child-${childIndex}-id`)?.value);
            const expected = addTrack && columnIndex === columnCount
              ? []
              : beforeColumns[columnIndex];
            if (ids.some((id) => typeof id !== "string" || id === "") ||
                new Set(ids).size !== ids.length ||
                JSON.stringify(ids) !== JSON.stringify(expected)) return;
          }
          const buttons = [...form.elements].filter((control) =>
            control.name === "column-action" && !control.disabled);
          const lastTrack = buttons.find((control) =>
            control.value === `add:${nextColumnCount - 1}`);
          const globalAdd = buttons.find((control) => control.value === "add-column");
          (lastTrack || globalAdd)?.focus();
        };
      }
    }
    const nestedMatch = /^(section|column|terminal)-action$/.exec(submitter?.name || "");
    if (nestedMatch) {
      if (document.activeElement !== submitter) return () => {};
      const prefix = nestedMatch[1];
      const value = submitter.value || "";
      let columnIndex = null;
      let kind = null;
      let index = null;
      let rowId = null;
      let beforeIds = [];
      let beforeColumns = null;
      if (prefix !== "column") {
        const count = Number(form.elements.namedItem(`${prefix}-child-count`)?.value);
        if (!Number.isSafeInteger(count) || count < 0) return () => {};
        if (prefix === "terminal" && (count !== 0 || value !== "add")) return () => {};
        beforeIds = Array.from({ length: count }, (_unused, rowIndex) =>
          form.elements.namedItem(`${prefix}-child-${rowIndex}-id`)?.value);
        if (beforeIds.some((id) => typeof id !== "string" || id === "") ||
            new Set(beforeIds).size !== beforeIds.length) return () => {};
        if (value === "add") {
          kind = "add";
          index = count;
          rowId = form.elements.namedItem(`${prefix}-new-child-id`)?.value;
        } else {
          const matches = beforeIds.flatMap((id, rowIndex) =>
            ["up", "down", "remove"].filter((candidate) =>
              value === `${candidate}:${id}`).map((candidate) => [candidate, rowIndex, id]));
          if (matches.length !== 1) return () => {};
          [[kind, index, rowId]] = matches;
        }
      } else {
        const columnCount = Number(form.elements.namedItem("column-count")?.value);
        if (!Number.isSafeInteger(columnCount) || columnCount < 0) return () => {};
        const matches = [];
        beforeColumns = [];
        for (let candidateColumn = 0; candidateColumn < columnCount; candidateColumn += 1) {
          const count = Number(
            form.elements.namedItem(`column-${candidateColumn}-child-count`)?.value,
          );
          if (!Number.isSafeInteger(count) || count < 0) return () => {};
          const ids = Array.from({ length: count }, (_unused, rowIndex) =>
            form.elements.namedItem(`column-${candidateColumn}-child-${rowIndex}-id`)?.value);
          if (ids.some((id) => typeof id !== "string" || id === "") ||
              new Set(ids).size !== ids.length) return () => {};
          beforeColumns.push(ids);
          if (value === `add:${candidateColumn}`) {
            matches.push(["add", candidateColumn, count,
              form.elements.namedItem("column-new-child-id")?.value, ids]);
          }
          ids.forEach((id, rowIndex) => {
            ["up", "down", "remove"].forEach((candidate) => {
              if (value === `${candidate}:${candidateColumn}:${id}`) {
                matches.push([candidate, candidateColumn, rowIndex, id, ids]);
              }
            });
          });
        }
        if (matches.length !== 1) return () => {};
        [[kind, columnIndex, index, rowId, beforeIds]] = matches;
      }
      if (typeof rowId !== "string" || rowId === "" ||
          (kind === "up" && index === 0) ||
          (kind === "down" && index === beforeIds.length - 1)) return () => {};
      const expectedIds = [...beforeIds];
      if (kind === "add") expectedIds.push(rowId);
      if (kind === "remove") expectedIds.splice(index, 1);
      if (kind === "up") [expectedIds[index - 1], expectedIds[index]] =
        [expectedIds[index], expectedIds[index - 1]];
      if (kind === "down") [expectedIds[index], expectedIds[index + 1]] =
        [expectedIds[index + 1], expectedIds[index]];
      const nextCount = expectedIds.length;
      return () => {
        if (!form.isConnected ||
            (document.activeElement !== submitter &&
              !(document.activeElement === document.body && !submitter.isConnected))) return;
        const nextColumnCount = prefix === "column"
          ? Number(form.elements.namedItem("column-count")?.value)
          : null;
        if (prefix === "column" &&
            nextColumnCount !== beforeColumns.length) return;
        if (prefix === "column") {
          for (let candidateColumn = 0; candidateColumn < nextColumnCount; candidateColumn += 1) {
            if (candidateColumn === columnIndex) continue;
            const count = Number(
              form.elements.namedItem(`column-${candidateColumn}-child-count`)?.value,
            );
            const ids = Array.from(
              { length: Number.isSafeInteger(count) && count >= 0 ? count : 0 },
              (_unused, rowIndex) => form.elements.namedItem(
                `column-${candidateColumn}-child-${rowIndex}-id`,
              )?.value,
            );
            if (count !== beforeColumns[candidateColumn].length ||
                JSON.stringify(ids) !== JSON.stringify(beforeColumns[candidateColumn])) return;
          }
        }
        const actualCount = Number(form.elements.namedItem(prefix !== "column"
          ? `${prefix}-child-count`
          : `column-${columnIndex}-child-count`)?.value);
        if (actualCount !== nextCount) return;
        const afterIds = Array.from({ length: nextCount }, (_unused, rowIndex) =>
          form.elements.namedItem(prefix !== "column"
            ? `${prefix}-child-${rowIndex}-id`
            : `column-${columnIndex}-child-${rowIndex}-id`)?.value);
        if (afterIds.some((id) => typeof id !== "string" || id === "") ||
            new Set(afterIds).size !== afterIds.length ||
            JSON.stringify(afterIds) !== JSON.stringify(expectedIds)) return;
        const nextIndex = kind === "remove" ? Math.min(index, nextCount - 1) : expectedIds.indexOf(rowId);
        if (nextCount > 0 &&
            (!Number.isSafeInteger(nextIndex) || nextIndex < 0 || nextIndex >= nextCount)) return;
        const targetId = nextCount > 0 ? afterIds[nextIndex] : null;
        const actionName = `${prefix}-action`;
        const actionValue = (candidate, id) => prefix !== "column"
          ? `${candidate}:${id}`
          : `${candidate}:${columnIndex}:${id}`;
        const buttons = [...form.elements].filter((control) =>
          control.name === actionName && !control.disabled);
        const exact = kind !== "add" && kind !== "remove" && targetId
          ? buttons.find((control) => control.value === actionValue(kind, targetId))
          : null;
        const rowControl = targetId && (exact || ["up", "down", "remove"].map((candidate) =>
          buttons.find((control) => control.value === actionValue(candidate, targetId))).find(Boolean));
        const add = buttons.find((control) => control.value ===
          (prefix !== "column" ? "add" : `add:${columnIndex}`));
        if (kind === "add") {
          const contextualEditor = form.closest(".bp-paper-contextual-editor");
          const directWrapper = targetId && document.getElementById(`paper-ed-${targetId}`);
          const directBody = directWrapper && contextualEditor?.contains(directWrapper)
            ? directWrapper.querySelector('bp-paper-editor [contenteditable="true"]')
            : null;
          const canvas = directBody ? null : contextualEditor && [...contextualEditor.querySelectorAll(
            "bp-paper-canvas",
          )].find((editor) => Array.isArray(editor.blocks) &&
            editor.blocks.some((block) => block?.id === targetId));
          const canvasBody = canvas?.querySelector('[contenteditable="true"]');
          const body = directBody || canvasBody;
          body?.focus();
          if (document.activeElement !== body) add?.focus();
          return;
        }
        (rowControl || add)?.focus();
      };
    }
    const match = /^(note|tab|param|ref|bar|toc|criterion|gauge|panel|step|question)-action$/.exec(submitter?.name || "");
    if (!match || document.activeElement !== submitter) return () => {};
    const prefix = match[1];
    const count = Number(form.elements.namedItem(`${prefix}-count`)?.value);
    const stableRows = ["panel", "step", "question"].includes(prefix);
    const action = stableRows
      ? /^(add|up|down|remove)(?::(.+))?$/.exec(submitter.value || "")
      : /^(add|up|down|remove)(?::(\d+))?$/.exec(submitter.value || "");
    if (!Number.isSafeInteger(count) || count < 0 || !action) return () => {};
    const kind = action[1];
    const beforeIds = stableRows
      ? Array.from({ length: count }, (_unused, index) =>
          form.elements.namedItem(`${prefix}-${index}-${prefix === "question" ? "original-id" : "id"}`)?.value)
      : [];
    const actionIndex = stableRows ? beforeIds.indexOf(action[2]) : Number(action[2]);
    const rowId = stableRows
      ? (kind === "add"
          ? form.elements.namedItem(`${prefix}-${prefix === "question" ? "new-id" : "new-row-id"}`)?.value
          : prefix === "question"
            ? form.elements.namedItem(`${prefix}-${actionIndex}-id`)?.value
            : action[2])
      : null;
    const index = actionIndex;
    if (stableRows &&
        (beforeIds.some(id => typeof id !== "string" || id === "") ||
          new Set(beforeIds).size !== beforeIds.length ||
          typeof rowId !== "string" || rowId === "" ||
          (kind !== "add" && (index < 0 || beforeIds.lastIndexOf(action[2]) !== index)))) return () => {};
    if (!stableRows && kind !== "add" &&
        (!Number.isSafeInteger(index) || index < 0 || index >= count)) return () => {};
    const nextCount = count + (kind === "add" ? 1 : kind === "remove" ? -1 : 0);
    return () => {
      if (!form.isConnected ||
          (document.activeElement !== submitter &&
            !(document.activeElement === document.body && !submitter.isConnected)) ||
          Number(form.elements.namedItem(`${prefix}-count`)?.value) !== nextCount) return;
      const afterIds = stableRows
        ? Array.from({ length: nextCount }, (_unused, rowIndex) =>
            form.elements.namedItem(`${prefix}-${rowIndex}-id`)?.value)
        : [];
      if (stableRows &&
          (afterIds.some(id => typeof id !== "string" || id === "") ||
            new Set(afterIds).size !== afterIds.length)) return;
      const nextIndex = stableRows
        ? (kind === "remove" ? Math.min(index, nextCount - 1) : afterIds.indexOf(rowId))
        : kind === "add" ? count : kind === "up" ? index - 1
          : kind === "down" ? index + 1 : Math.min(index, nextCount - 1);
      if (nextCount > 0 &&
          (!Number.isSafeInteger(nextIndex) || nextIndex < 0 || nextIndex >= nextCount)) return;
      const controls = [...form.elements];
      const field = nextCount > 0 && controls.find(control =>
        control.name?.startsWith(`${prefix}-${nextIndex}-`) &&
        !control.disabled && control.type !== "hidden");
      const fallback = controls.find(control => control.name === `${prefix}-action` &&
        control.value === (nextCount
          ? `remove:${stableRows ? afterIds[nextIndex] : nextIndex}`
          : "add") && !control.disabled);
      (field || fallback)?.focus();
    };
  }

  function bpPaperOptionFocus(form, submitter) {
    if (submitter?.name !== "option-action" || document.activeElement !== submitter) {
      return () => {};
    }
    const add = /^add:(.+)$/.exec(submitter.value || "");
    const positional = /^(up|down|remove):(.+):(\d+)$/.exec(submitter.value || "");
    const kind = add ? "add" : positional?.[1];
    const originalId = add?.[1] || positional?.[2];
    const index = add ? null : Number(positional?.[3]);
    const questionCount = Number(form.elements.namedItem("question-count")?.value);
    if (!kind || !originalId || !Number.isSafeInteger(questionCount) || questionCount < 0) {
      return () => {};
    }
    const originalIds = Array.from({ length: questionCount }, (_unused, rowIndex) =>
      form.elements.namedItem(`question-${rowIndex}-original-id`)?.value);
    const questionIndex = originalIds.indexOf(originalId);
    if (questionIndex < 0 || originalIds.lastIndexOf(originalId) !== questionIndex) return () => {};
    const answerId = form.elements.namedItem(`question-${questionIndex}-id`)?.value;
    const count = Number(form.elements.namedItem(`question-${questionIndex}-option-count`)?.value);
    if (typeof answerId !== "string" || answerId === "" ||
        !Number.isSafeInteger(count) || count < 0 ||
        (kind !== "add" && (!Number.isSafeInteger(index) || index < 0 || index >= count)) ||
        (kind === "up" && index === 0) || (kind === "down" && index === count - 1)) {
      return () => {};
    }
    const nextCount = count + (kind === "add" ? 1 : kind === "remove" ? -1 : 0);
    const nextIndex = kind === "add" ? count : kind === "up" ? index - 1
      : kind === "down" ? index + 1 : Math.min(index, nextCount - 1);
    return () => {
      if (!form.isConnected ||
          (document.activeElement !== submitter &&
            !(document.activeElement === document.body && !submitter.isConnected))) return;
      const nextQuestionCount = Number(form.elements.namedItem("question-count")?.value);
      const nextQuestionIndex = Array.from(
        { length: Number.isSafeInteger(nextQuestionCount) ? nextQuestionCount : 0 },
        (_unused, rowIndex) => form.elements.namedItem(`question-${rowIndex}-id`)?.value,
      ).indexOf(answerId);
      if (nextQuestionCount !== questionCount || nextQuestionIndex < 0 ||
          Number(form.elements.namedItem(`question-${nextQuestionIndex}-option-count`)?.value) !== nextCount) return;
      const option = nextCount > 0
        ? form.elements.namedItem(`question-${nextQuestionIndex}-option-${nextIndex}`)
        : form.elements.namedItem(`question-${nextQuestionIndex}-id`);
      if (option && !option.disabled) option.focus();
    };
  }

  // Stable collection inserts consume their client-carried id exactly once.
  // LiveView can repaint an older hidden input value while morphing an active
  // form, so mint afresh after every acknowledged insert. Failed and
  // transport-ambiguous writes keep the same value for exact replay.
  function bpPaperRotateConsumedCollectionId(form, submitter) {
    const match = /^(panel|step|question|section|column|terminal)-action$/.exec(submitter?.name || "");
    if (!match) return () => {};
    const prefix = match[1];
    const value = submitter.value || "";
    let name;
    if (prefix === "section" || prefix === "terminal") {
      if (value !== "add") return () => {};
      name = `${prefix}-new-child-id`;
    } else if (prefix === "column") {
      const add = /^add:(0|[1-9]\d*)$/.exec(value);
      if (!add || !Number.isSafeInteger(Number(add[1]))) return () => {};
      name = "column-new-child-id";
    } else {
      const action = /^(add|add-body)(?::.+)?$/.exec(value);
      if (!action) return () => {};
      name = prefix === "question" ? "question-new-id"
        : `${prefix}-${action[1] === "add" ? "new-row-id" : "new-child-id"}`;
    }
    const consumed = form.elements.namedItem(name)?.value;
    if (typeof consumed !== "string" || consumed === "") return () => {};
    return () => {
      if (!form.isConnected) return;
      const input = form.elements.namedItem(name);
      if (!input) return;
      const replacement = bpPaperRequestId();
      if (replacement) {
        input.value = `b-${replacement}`;
        input.defaultValue = input.value;
      }
    };
  }

  // Validate the currently authored numeric constraints together. Mirroring
  // stored min/max attributes would reject a coherent new range, while only
  // validating on the server lets a failed patch repaint away the local draft.
  function bpPaperValidateAuthoringForm(form) {
    const editor = form.getAttribute?.("data-test-id");

    if (["paper-toc-editor", "paper-criteria-progress-editor", "paper-gauge-list-editor"].includes(editor)) {
      const fields = [...form.elements].filter((field) => {
        const name = field.name || "";
        return editor === "paper-toc-editor"
          ? name === "depth" || /^toc-\d+-level$/.test(name)
          : editor === "paper-gauge-list-editor"
            ? name === "max" || /^gauge-\d+-value$/.test(name)
            : /^criterion-\d+-(met|total)$/.test(name);
      });
      const positiveInteger = (value) => /^[+-]?\d+$/.test(value) && Number(value) > 0;
      const finiteNumber = (value) =>
        /^[+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/.test(value) &&
        Number.isFinite(Number(value));

      fields.forEach((field) => {
        field.setCustomValidity?.("");
        // A malformed authored legacy value is a valid no-op. Once changed,
        // apply the same fail-closed numeric shape expected by the server.
        if (field.value === field.defaultValue) return;
        const value = field.value.trim();
        const gaugeMaximum = editor === "paper-gauge-list-editor" && field.name === "max";
        const valid = editor === "paper-toc-editor"
          ? positiveInteger(value)
          : gaugeMaximum
            ? field.value === "" || (finiteNumber(value) && Number(value) > 0)
            : finiteNumber(value);
        if (!valid) {
          field.setCustomValidity?.(editor === "paper-toc-editor"
            ? "Enter a positive whole number."
            : gaugeMaximum ? "Enter a number greater than zero, or leave blank for automatic."
              : "Enter a number.");
        }
      });
      return;
    }

    if (editor === "paper-form-editor") {
      const count = Number(form.elements.namedItem("question-count")?.value);
      if (!Number.isSafeInteger(count) || count < 0) return;
      for (let index = 0; index < count; index += 1) {
        const min = form.elements.namedItem(`question-${index}-scale-min`);
        const max = form.elements.namedItem(`question-${index}-scale-max`);
        if (!min || !max) continue;
        min.setCustomValidity?.("");
        max.setCustomValidity?.("");
        const integer = (field) => /^[+-]?\d+$/.test(field.value.trim());
        const minValid = integer(min);
        const maxValid = integer(max);
        if (!minValid) min.setCustomValidity?.("Enter a whole number.");
        if (!maxValid) max.setCustomValidity?.("Enter a whole number.");
        const boundsChanged = min.value !== min.defaultValue || max.value !== max.defaultValue;
        if (boundsChanged && minValid && maxValid &&
            BigInt(min.value.trim()) > BigInt(max.value.trim())) {
          max.setCustomValidity?.("Maximum must be at least the minimum.");
        }
      }
      return;
    }

    if (editor !== "paper-field-number-editor") return;
    const fields = Object.fromEntries(["value", "min", "max", "step"].map((name) =>
      [name, form.querySelector(`[name="${name}"]`)]));
    Object.values(fields).forEach((field) => field?.setCustomValidity(""));
    const number = (name) => fields[name]?.value.trim() ? Number(fields[name].value) : null;
    const value = number("value"), min = number("min"), max = number("max"), step = number("step");
    if (step != null && step <= 0) fields.step?.setCustomValidity("Step must be greater than zero.");
    if (min != null && max != null && min > max) {
      fields.max?.setCustomValidity("Maximum must be at least the minimum.");
    } else if (value != null && min != null && value < min) {
      fields.value?.setCustomValidity(`Value must be at least ${min}.`);
    } else if (value != null && max != null && value > max) {
      fields.value?.setCustomValidity(`Value must be at most ${max}.`);
    }
  }
  const PAPER_HISTORY_POSITION = "__bpPaperHistoryPosition";

  function bpPaperOwnedHistoryPosition(state) {
    return Number.isFinite(state?.[PAPER_HISTORY_POSITION])
      ? state[PAPER_HISTORY_POSITION]
      : null;
  }

  function bpPaperPhoenixHistoryPosition(state) {
    if (Number.isFinite(state?.position)) return state.position;
    if (state?.backType === "patch" || state?.backType === "redirect") return 0;
    return null;
  }

  function bpPaperHistoryStateWithPosition(state, position) {
    if (state == null) return { [PAPER_HISTORY_POSITION]: position };
    if (typeof state !== "object" || Array.isArray(state)) return state;
    const prototype = Object.getPrototypeOf(state);
    if (prototype !== null && prototype?.constructor?.name !== "Object") return state;
    return { ...state, [PAPER_HISTORY_POSITION]: position };
  }

  // Loaded before LiveSocket: mark the current entry and every later History
  // API entry without replacing state owned by Phoenix or another client.
  // Entries created before this script remain unknowable on browsers without
  // the Navigation API, so the popstate fallback never guesses their direction.
  function bpPaperInstallHistoryMetadata() {
    const history = window.history;
    if (!history || history.__bpPaperHistoryInstalled) return;
    const nativePushState = history.pushState.bind(history);
    const nativeReplaceState = history.replaceState.bind(history);
    let position = bpPaperOwnedHistoryPosition(history.state);
    const navigationPosition = window.navigation?.currentEntry?.index;
    if (position == null && Number.isFinite(navigationPosition)) position = navigationPosition;
    if (position == null) position = bpPaperPhoenixHistoryPosition(history.state);
    if (position == null) position = 0;
    history.pushState = function (state, title, url) {
      const current = bpPaperOwnedHistoryPosition(history.state) ??
        bpPaperPhoenixHistoryPosition(history.state);
      position = (current ?? position) + 1;
      return nativePushState(bpPaperHistoryStateWithPosition(state, position), title, url);
    };
    history.replaceState = function (state, title, url) {
      const current = bpPaperOwnedHistoryPosition(history.state) ??
        bpPaperPhoenixHistoryPosition(history.state);
      position = current ?? bpPaperPhoenixHistoryPosition(state) ?? position;
      return nativeReplaceState(bpPaperHistoryStateWithPosition(state, position), title, url);
    };
    window.addEventListener("popstate", (event) => {
      const next = bpPaperOwnedHistoryPosition(event.state) ??
        bpPaperPhoenixHistoryPosition(event.state);
      if (next != null) position = next;
    });
    Object.defineProperty(history, "__bpPaperHistoryInstalled", { value: true });
  }

  bpPaperInstallHistoryMetadata();

  function bpPaperRequestId() {
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
        hex.slice(0, 4).join(""), hex.slice(4, 6).join(""),
        hex.slice(6, 8).join(""), hex.slice(8, 10).join(""),
        hex.slice(10, 16).join(""),
      ].join("-");
    } catch (_) {
      return null;
    }
  }

  function bpPaperRevisionFrom(el) {
    if (!el) return null;
    if (el.dataset.paperRev != null && /^\d+$/.test(el.dataset.paperRev)) {
      return Number(el.dataset.paperRev);
    }
    if (typeof el.dataset.documentRev === "string" && el.dataset.documentRev !== "") {
      return el.dataset.documentRev;
    }
    return null;
  }

  function bpPaperReplyFrom(results) {
    if (!Array.isArray(results) || results.length === 0) return null;
    const replies = results
      .filter((result) => result.status === "fulfilled")
      .map((result) => result.value?.reply);
    return replies.length === results.length && replies.length === 1 ? replies[0] : null;
  }

  function bpPaperMutation(hook, source, event, payload, options = {}) {
    const coordinator = hook._exitCoordinator;
    const send = options.target == null
      ? (wire) => hook.pushEvent(event, wire)
      : (wire) => Promise.resolve(hook.pushEventTo(options.target, event, wire))
        .then(bpPaperReplyFrom);
    if (!coordinator) {
      const requestId = bpPaperRequestId();
      if (!requestId) return { requestId: null, promise: Promise.resolve(false) };
      return {
        requestId,
        promise: Promise.resolve(send({ ...payload, request_id: requestId }))
          .then((reply) => reply?.saved === true && reply?.request_id === requestId)
          .catch(() => false),
      };
    }
    return coordinator.mutate(source, {
      requestId: options.requestId,
      payload,
      send,
      onResult: options.onResult,
      reviewRequired: options.reviewRequired === true,
      kind: options.kind,
      trackDraft: options.trackDraft,
      historyDirection: options.historyDirection,
      historyStep: options.historyStep,
    });
  }

  function bpPaperContextualHistoryStep(value, requestId, expectedAction) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    if (Object.keys(value).sort().join("\n") !== "action\nref\nversion") return null;
    if (value.version !== 1 || value.ref !== requestId || value.action !== expectedAction) {
      return null;
    }
    return { version: 1, ref: value.ref, action: value.action };
  }

  function bpPaperHistoryPosition(state) {
    const navigationPosition = window.navigation?.currentEntry?.index;
    if (Number.isFinite(navigationPosition)) return navigationPosition;
    const ownedPosition = bpPaperOwnedHistoryPosition(state);
    if (ownedPosition != null) return ownedPosition;
    const phoenixPosition = bpPaperPhoenixHistoryPosition(state);
    if (phoenixPosition != null) return phoenixPosition;
    return null;
  }

  function bpPaperEventParams(el, base = {}) {
    const params = { ...base };
    for (const attr of el?.attributes || []) {
      if (attr.name.startsWith("phx-value-")) {
        params[attr.name.slice("phx-value-".length)] = attr.value;
      }
    }
    return params;
  }

  function bpPaperFallbackFormSnapshot(form, identity) {
    const controls = [...form.elements].filter((control) => control.name);
    const editable = controls.filter((control) =>
      !["hidden", "submit", "button", "reset", "image"].includes(control.type));
    const signature = controls.map((control) =>
      `${control.tagName}:${control.type}:${control.name}`).join("\n");
    const counts = controls.filter((control) =>
      /^(note|tab|param|ref|bar|toc|criterion|gauge|panel|step|question)-count$/.test(control.name));
    const stableRowIds = ["panel", "step", "question"].flatMap((prefix) => {
      const count = Number(form.elements.namedItem(`${prefix}-count`)?.value);
      if (!Number.isSafeInteger(count) || count < 0) return [];
      return [[prefix, Array.from({ length: count }, (_unused, index) =>
        form.elements.namedItem(
          `${prefix}-${index}-${prefix === "question" ? "original-id" : "id"}`,
        )?.value ?? null)]];
    });
    const blockId = controls.find((control) => control.name === "block_id")?.value ?? null;
    return {
      form,
      formId: form.id,
      editor: form.getAttribute("data-test-id"),
      documentKey: identity.key,
      documentRevision: identity.rev,
      blockId,
      signature,
      controlRefs: controls,
      countValues: counts.map((control) => [control.name, control.value]),
      stableRowIds,
      fields: editable.map((control) => ({
        control,
        value: control.value,
        checked: control.checked,
        selected: control.tagName === "SELECT"
          ? [...control.options].map((option) => option.selected)
          : null,
      })),
      reviewFields: [...editable, ...controls.filter((control) => control.type === "hidden" &&
        (/^section-(?:child-count|child-\d+-id|new-child-id)$/.test(control.name) ||
          /^column-(?:count|new-child-id|\d+-child-count|\d+-child-\d+-id)$/.test(control.name)))]
        .map((control) => ({
        control,
        value: control.value,
        checked: control.checked,
        selected: control.tagName === "SELECT"
          ? [...control.options].map((option) => option.selected)
          : null,
      })),
    };
  }

  function bpPaperRestoreFallbackForm(snapshot, form, identity, main) {
    if (!snapshot || snapshot.form !== form || !form.isConnected || !main.contains(form) ||
        snapshot.formId !== form.id || snapshot.editor !== form.getAttribute("data-test-id") ||
        snapshot.documentKey !== identity.key || snapshot.documentRevision !== identity.rev) {
      return false;
    }
    const controls = [...form.elements].filter((control) => control.name);
    const blockId = controls.find((control) => control.name === "block_id")?.value ?? null;
    const signature = controls.map((control) =>
      `${control.tagName}:${control.type}:${control.name}`).join("\n");
    const counts = controls.filter((control) =>
      /^(note|tab|param|ref|bar|toc|criterion|gauge|panel|step|question)-count$/.test(control.name));
    const countValues = counts.map((control) => [control.name, control.value]);
    const stableRowIds = ["panel", "step", "question"].flatMap((prefix) => {
      const count = Number(form.elements.namedItem(`${prefix}-count`)?.value);
      if (!Number.isSafeInteger(count) || count < 0) return [];
      return [[prefix, Array.from({ length: count }, (_unused, index) =>
        form.elements.namedItem(
          `${prefix}-${index}-${prefix === "question" ? "original-id" : "id"}`,
        )?.value ?? null)]];
    });
    if (snapshot.blockId !== blockId || snapshot.signature !== signature ||
        JSON.stringify(snapshot.countValues) !== JSON.stringify(countValues) ||
        JSON.stringify(snapshot.stableRowIds) !== JSON.stringify(stableRowIds) ||
        controls.length !== snapshot.controlRefs.length ||
        controls.some((control, index) => control !== snapshot.controlRefs[index]) ||
        snapshot.fields.some(({ control }) => !control.isConnected || control.form !== form)) {
      return false;
    }
    snapshot.fields.forEach(({ control, value, checked, selected }) => {
      if (selected) {
        [...control.options].forEach((option, index) => {
          option.selected = selected[index] === true;
        });
      } else if (control.type === "checkbox" || control.type === "radio") {
        control.checked = checked;
      } else {
        control.value = value;
      }
    });
    return true;
  }

  function bpPaperPositionalCollectionEntry(entry) {
    if (entry?.payload?.op === "patch-table-structure") return true;
    return Object.keys(entry?.payload || {}).some((key) =>
      PAPER_POSITIONAL_COLLECTION_PARAM.test(key));
  }

  function bpPaperPositionalCollectionActionEntry(entry) {
    return Object.entries(entry?.payload || {}).some(([key, value]) =>
      PAPER_POSITIONAL_COLLECTION_ACTION_PARAM.test(key) && value !== "");
  }

  function bpPaperConflictDraft(entry, snapshot) {
    const identity = snapshot ? {
      documentKey: snapshot.documentKey,
      documentRevision: snapshot.documentRevision,
      formId: snapshot.formId,
      editor: snapshot.editor,
      blockId: snapshot.blockId,
    } : {
      documentKey: entry?.documentKey ?? null,
      documentRevision: entry?.authoredRev ?? null,
      blockId: entry?.payload?.block_id ?? null,
    };
    const structure = snapshot ? {
      fieldSignature: snapshot.signature,
      collectionCounts: snapshot.countValues,
      stableRowIds: snapshot.stableRowIds,
    } : null;
    const snapshotValues = snapshot
      ? (snapshot.reviewFields || snapshot.fields).map(({ control, value, checked, selected }) => ({
        name: control.name,
        type: control.type,
        value,
        ...(control.type === "checkbox" || control.type === "radio" ? { checked } : {}),
        ...(selected ? { selected } : {}),
      }))
      : [];
    const snapshotNames = new Set(snapshotValues.map(({ name }) => name));
    const entryValues = Object.entries(entry?.payload || {})
      .filter(([name]) => !snapshotNames.has(name))
      .map(([name, value]) => ({ name, value }));
    const values = [...snapshotValues, ...entryValues];
    return { identity, structure, values };
  }

  function bpPaperExitCoordinator(hook) {
    if (hook._bpPaperExitCoordinator) return hook._bpPaperExitCoordinator;
    let main = hook.el.closest?.("main");
    if (!main) return null;
    let coordinator = paperExitCoordinators.get(main);
    if (!coordinator) {
      const sources = new Map();
      let nativeFocusBaselines = new WeakMap();
      const members = new Set();
      const replayTargets = new WeakSet();
      let actionPending = false;
      let historyPosition = bpPaperHistoryPosition(window.history.state);
      let historyPhase = null;
      let historyDelta = null;
      let historySaveResult = null;
      let navigationReplayKey = null;
      let navigationSave = null;
      const mutationQueue = [];
      const mutationById = new Map();
      const ownRevisions = new Map();
      const quarantinedEchoes = [];
      const detachedReferenceDrafts = [];
      const contextualHistory = { undo: [], redo: [] };
      let mutationActive = false;
      let mutationPaused = false;
      let conflict = null;
      let pendingIdentity = null;
      let reloadWhenClean = false;
      let discardReloadBypass = false;
      let historyRequestPending = null;
      const initialCarrier = hook.el.closest?.("[data-paper-doc-key]") ||
        main.querySelector("[data-paper-doc-key]");
      let documentKey = initialCarrier?.dataset.paperDocKey || null;
      let confirmedRevision = bpPaperRevisionFrom(initialCarrier);

      const historyStack = (direction) => contextualHistory[direction];
      const historyPendingEntry = () => mutationQueue.find((entry) => entry.kind === "history");
      const historyTop = (direction) => historyStack(direction)?.at(-1) || null;
      const historyReason = (entry) => {
        const code = entry?.disabledReason;
        if (code === "history_expired" || code === "history_ref_expired" ||
            code === "idempotency_receipt_expired") {
          return "This change is more than one hour old and can no longer be restored.";
        }
        if (code === "history_ref_consumed") {
          return "This history step was already used. Make a new edit to continue.";
        }
        if (code === "history_conflict") {
          return "This change no longer matches the current document.";
        }
        if (code === "history_unavailable") {
          return "This history step is no longer available for this document.";
        }
        if (code === "invalid_history_request") {
          return "This history step could not be validated.";
        }
        return code ? "This history step is unavailable." : "";
      };

      const renderHistoryControls = () => {
        const pending = historyPendingEntry();
        for (const direction of ["undo", "redo"]) {
          const top = historyTop(direction);
          main.querySelectorAll(`[data-paper-history-action="${direction}"]`).forEach((control) => {
            const retryable = pending?.historyDirection === direction &&
              !mutationActive && !conflict && mutationPaused && !top?.disabledReason;
            const disabled = !top || Boolean(top.disabledReason) ||
              (Boolean(pending) && !retryable) || Boolean(historyRequestPending) ||
              Boolean(conflict);
            control.disabled = disabled;
            control.setAttribute("aria-disabled", String(disabled));
            control.dataset.paperHistoryState = top?.disabledReason
              ? "blocked"
              : pending?.historyDirection === direction
                ? (retryable ? "retry" : "pending")
                : historyRequestPending === direction ? "waiting"
                : top ? "ready" : "empty";
            control.title = historyReason(top);
          });
        }
        const status = main.querySelector('[data-paper-history-status][role="status"]');
        if (status) {
          const blocked = historyTop("undo")?.disabledReason
            ? historyTop("undo")
            : historyTop("redo")?.disabledReason ? historyTop("redo") : null;
          const activeDirection = pending?.historyDirection || historyRequestPending;
          status.textContent = blocked
            ? historyReason(blocked)
            : pending && mutationPaused && !mutationActive
              ? `${pending.historyDirection === "undo" ? "Undo" : "Redo"} was not confirmed. Try again.`
              : activeDirection
                ? `${activeDirection === "undo" ? "Undoing" : "Redoing"}…`
                : "";
        }
      };

      const makeHistoryEntry = (step) => {
        const requestId = bpPaperRequestId();
        return requestId ? {
          ...step,
          requestId,
          expiresAt: Date.now() + PAPER_OP_RETRY_TTL_MS,
          disabledReason: null,
        } : null;
      };

      const pushHistory = (direction, step) => {
        const entry = makeHistoryEntry(step);
        if (!entry) return false;
        const stack = historyStack(direction);
        stack.push(entry);
        if (stack.length > PAPER_CONTEXTUAL_HISTORY_LIMIT) {
          stack.splice(0, stack.length - PAPER_CONTEXTUAL_HISTORY_LIMIT);
        }
        return true;
      };

      const setSaveStatus = (text, force = false) => {
        const status = main.querySelector(
          '[data-test-id="bp-paper-footer-save"][role="status"]',
        );
        if (status && (force || PAPER_TRANSIENT_SAVE_STATUSES.has(status.textContent.trim()))) {
          status.textContent = text;
        }
      };

      const renderSaveStatus = (acknowledged = false) => {
        const invalidFallback = [...sources].some(([source, record]) =>
          record.dirty && source.isConnected &&
          source.matches?.(".bp-paper-edit-form[phx-change]") &&
          source.checkValidity?.() === false);
        if (conflict || detachedReferenceDrafts.length) {
          return setSaveStatus("Save paused — review required.");
        }
        if (invalidFallback) {
          return setSaveStatus("Unsaved changes — fix invalid fields.");
        }
        if (mutationPaused) return setSaveStatus("Save paused — retry required.");
        if (coordinator.hasUnsaved() || mutationActive || mutationQueue.length) {
          return setSaveStatus("Saving…");
        }
        setSaveStatus(acknowledged ? "✓ Auto-saved" : "", acknowledged);
      };

      const identityFor = (source) => {
        const carrier = source?.closest?.("[data-paper-doc-key]");
        return {
          key: carrier?.dataset.paperDocKey || documentKey,
          rev: bpPaperRevisionFrom(carrier),
        };
      };

      const captureHistoryPosition = () => {
        const currentPosition = bpPaperHistoryPosition(window.history.state);
        if (currentPosition != null) historyPosition = currentPosition;
      };

      const recordFor = (source) => {
        let record = sources.get(source);
        if (!record) {
          const identity = identityFor(source);
          record = {
            version: 0,
            dirtyToken: null,
            active: 0,
            dirty: false,
            timer: null,
            pending: null,
            authoredRev: undefined,
            mutationEntry: null,
            fallbackDeferred: false,
            fallbackUnsafe: false,
            documentKey: identity.key,
            documentRevision: identity.rev,
          };
          sources.set(source, record);
        }
        return record;
      };

      const advanceFocusedReferenceCopySibling = (entry) => {
        const acknowledged = bpPaperLinkReferenceCopySource(entry?.payload);
        if (!acknowledged || entry.ifRev == null || entry.documentKey !== documentKey ||
            quarantinedEchoes.some((echo) =>
              (!echo.documentKey || echo.documentKey === entry.documentKey) &&
              echo.requestId !== entry.requestId)) return false;
        const identityKeys = [
          "block_id", "paper-link-ref-index", "paper-link-ref-slug", "paper-link-ref-guard",
        ];
        const sibling = [...main.querySelectorAll(".bp-paper-edit-form[phx-change]")]
          .find((form) => {
            if (form === entry.source || !form.isConnected || !main.contains(form) ||
                !form.contains(document.activeElement) || sources.has(form) ||
                identityFor(form).key !== entry.documentKey) return false;
            const focused = nativeFocusBaselines.get(form);
            if (focused?.key !== entry.documentKey || focused.rev !== entry.ifRev) return false;
            const candidate = bpPaperLinkReferenceCopyForm(form);
            return candidate &&
              candidate["paper-link-ref-field"] !== acknowledged["paper-link-ref-field"] &&
              identityKeys.every((key) => candidate[key] === acknowledged[key]);
          });
        if (!sibling) return false;
        nativeFocusBaselines.get(sibling).rev = confirmedRevision;
        return true;
      };

      const nativeFormFor = (target) => target?.form?.matches?.(".bp-paper-edit-form[phx-change]")
        ? target.form : null;
      const authoredRevisionFor = (source, record) => {
        const focused = nativeFocusBaselines.get(source);
        if (focused?.key === record.documentKey) return focused.rev;
        return record.documentKey === documentKey ? confirmedRevision : record.documentRevision;
      };

      coordinator = {
        rebindMain(nextMain, observedDocumentKey) {
          if (!nextMain || nextMain === main) {
            if (nextMain === main) renderHistoryControls();
            return nextMain === main;
          }
          if (!observedDocumentKey || observedDocumentKey !== documentKey) return false;
          const occupied = paperExitCoordinators.get(nextMain);
          if (occupied && occupied !== coordinator) return false;
          if (paperExitCoordinators.get(main) === coordinator) {
            paperExitCoordinators.delete(main);
          }
          main = nextMain;
          paperExitCoordinators.set(main, coordinator);
          renderHistoryControls();
          return true;
        },
        refreshHistoryControls() {
          renderHistoryControls();
        },
        refreshPresentation() {
          renderHistoryControls();
          coordinator._renderConflict?.();
          renderSaveStatus();
        },
        register(member) {
          members.add(member);
          member._bpPaperExitCoordinator = coordinator;
          const carrier = member.el.closest?.("[data-paper-doc-key]");
          const nextKey = carrier?.dataset.paperDocKey;
          if (nextKey && nextKey !== documentKey) {
            const nextIdentity = { key: nextKey, rev: bpPaperRevisionFrom(carrier) };
            if (!coordinator.hasUnsaved() && !mutationQueue.length && !mutationActive) {
              coordinator._resetIdentity(nextIdentity);
            } else {
              pendingIdentity = nextIdentity;
            }
          }
          return coordinator;
        },
        release(member) {
          members.delete(member);
          member._bpPaperExitCoordinator = null;
          if (members.size) return;
          document.removeEventListener("input", coordinator._onInput);
          document.removeEventListener("change", coordinator._onInput);
          document.removeEventListener("focusin", coordinator._onNativeFocus);
          document.removeEventListener("focusout", coordinator._onNativeBlur);
          document.removeEventListener("click", coordinator._onClick, true);
          document.removeEventListener("submit", coordinator._onSubmit, true);
          window.removeEventListener("beforeunload", coordinator._onBeforeUnload);
          window.removeEventListener("popstate", coordinator._onPopState, true);
          window.removeEventListener("phx:navigate", coordinator._onNavigate);
          window.navigation?.removeEventListener?.("navigate", coordinator._onNavigationApiNavigate);
          sources.forEach((record) => clearTimeout(record.timer));
          contextualHistory.undo.length = 0;
          contextualHistory.redo.length = 0;
          historyRequestPending = null;
          paperExitCoordinators.delete(main);
        },
        markDirty(source) {
          if (!source) return null;
          captureHistoryPosition();
          const record = recordFor(source);
          if (record.authoredRev === undefined) {
            record.authoredRev = authoredRevisionFor(source, record);
          }
          record.version += 1;
          record.dirtyToken = {};
          record.dirty = true;
          return record.dirtyToken;
        },
        beginSave(source) {
          if (!source) return null;
          captureHistoryPosition();
          const record = recordFor(source);
          if (!record.dirty) {
            if (record.authoredRev === undefined) {
              record.authoredRev = authoredRevisionFor(source, record);
            }
            record.version += 1;
            record.dirty = true;
          }
          record.active += 1;
          return { source, version: record.version };
        },
        finishSave(token, saved) {
          if (!token) return;
          const record = sources.get(token.source);
          if (!record) return;
          record.active = Math.max(0, record.active - 1);
          if (saved === true && record.active === 0 && record.version === token.version) {
            record.dirty = false;
          }
          if (!record.dirty && record.active === 0) sources.delete(token.source);
        },
        settleNoop(source, expectedToken) {
          const record = sources.get(source);
          if (!record || record.dirty !== true || record.active !== 0 ||
              expectedToken == null || record.dirtyToken !== expectedToken ||
              mutationQueue.some((entry) => entry.source === source) ||
              conflict?.source === source) return false;
          clearTimeout(record.timer);
          sources.delete(source);
          renderSaveStatus();
          if (!coordinator._maybeAdoptPendingIdentity()) {
            coordinator._flushQuarantinedIfClean();
          }
          coordinator._pumpMutations();
          coordinator._reloadIfClean();
          return true;
        },
        hasUnsaved(includePendingHistoryAction = true) {
          if (detachedReferenceDrafts.length) return true;
          for (const record of sources.values()) {
            if (record.dirty || record.active > 0) return true;
          }
          return [...main.querySelectorAll("bp-paper-canvas, bp-paper-editor")]
            .some((editor) => editor.hasPendingChanges?.() === true) ||
            mutationQueue.some((entry) => entry.kind === "history") ||
            (includePendingHistoryAction && Boolean(historyRequestPending));
        },
        firstUnsavedWithin(root) {
          if (!root) return null;
          for (const [source, record] of sources) {
            if ((source === root || root.contains?.(source)) &&
                (record.dirty || record.active > 0)) return source;
          }
          const queued = mutationQueue.find((entry) =>
            entry.source === root || root.contains?.(entry.source));
          if (queued) return queued.source;
          const editor = [...(root.querySelectorAll?.("bp-paper-canvas, bp-paper-editor") || [])]
            .find((candidate) => candidate.hasPendingChanges?.() === true);
          return editor?.closest?.(PAPER_FLUSH_TARGETS) || null;
        },
        captureReferenceDraftReplacement(fromRoot, rootId, rootDocumentKey) {
          if (!fromRoot || !rootId || !rootDocumentKey ||
              fromRoot.dataset.paperDocKey !== rootDocumentKey) return false;
          const candidates = [];
          for (const [source, record] of sources) {
            if (record.documentKey !== rootDocumentKey ||
                (!record.dirty && record.active === 0) ||
                !(source === fromRoot || fromRoot.contains(source))) continue;
            const values = bpPaperLinkReferenceCopyForm(source);
            if (!values) continue;
            const capturedValues = { ...values };
            const capturedField = record.formSnapshot?.fields?.find(
              ({ control }) => control.name === "paper-link-ref-value",
            );
            if (typeof capturedField?.value === "string") {
              capturedValues["paper-link-ref-value"] = capturedField.value;
            }
            const snapshot = {
              identity: {
                documentKey: record.documentKey,
                documentRevision: record.authoredRev ?? record.documentRevision,
                formId: source.id || null,
                blockId: capturedValues.block_id,
              },
              structure: null,
              values: PAPER_LINK_REFERENCE_COPY_KEYS.map((name) => ({
                name,
                type: name === "paper-link-ref-value" ? "textarea" : "hidden",
                value: capturedValues[name],
              })),
            };
            candidates.push({
              source,
              documentKey: record.documentKey,
              field: capturedValues["paper-link-ref-field"],
              value: capturedValues["paper-link-ref-value"],
              snapshot,
            });
          }
          const hasRetainedDraft = detachedReferenceDrafts.some(
            (draft) => draft.documentKey === rootDocumentKey,
          );
          if (!candidates.length && !hasRetainedDraft) return false;
          Promise.resolve().then(() => {
            const currentRoot = document.getElementById(rootId);
            if (!currentRoot?.isConnected ||
                !currentRoot.matches?.(".bp-paper-editor[data-paper-doc-key]") ||
                currentRoot.dataset.paperDocKey !== rootDocumentKey) return;
            const nextMain = currentRoot.closest("main");
            if (!coordinator.rebindMain(nextMain, rootDocumentKey)) return;
            for (const candidate of candidates) {
              const record = sources.get(candidate.source);
              if (!record || (!record.dirty && record.active === 0) ||
                  candidate.source.isConnected ||
                  detachedReferenceDrafts.some((draft) => draft.source === candidate.source)) {
                continue;
              }
              detachedReferenceDrafts.push(candidate);
            }
            coordinator.refreshPresentation();
          });
          return true;
        },
        requestReloadWhenClean() {
          reloadWhenClean = true;
          return coordinator._reloadIfClean();
        },
        discardLocalDraftAndReload(reload = () => window.location.reload()) {
          // The recovery warning is an explicit destructive choice made after
          // the author has had an opportunity to export the frozen draft. Only
          // this document coordinator's unload prompt may be bypassed; do not
          // clear its DOM or queues before the browser starts the hard reload.
          discardReloadBypass = true;
          try {
            reload();
            return true;
          } catch (error) {
            discardReloadBypass = false;
            throw error;
          }
        },
        async drain() {
          while (main.isConnected) {
            const pending = [];
            const retainedStructural = mutationQueue[0];
            if (!mutationActive && mutationPaused && !conflict &&
                retainedStructural?.source?.matches?.("form[phx-submit]") &&
                !detachedReferenceDrafts.some(
                  (draft) => draft.source === retainedStructural.source,
                )) {
              pending.push(coordinator.retryMutation(retainedStructural));
            }
            main.querySelectorAll(PAPER_FLUSH_TARGETS).forEach((wrapper) => {
              wrapper.dispatchEvent(new CustomEvent("bp-flush-pending", {
                detail: { waitUntil: (promise) => pending.push(Promise.resolve(promise)) },
              }));
            });

            const driver = [...members].find(
              (member) => typeof member.pushEventTo === "function",
            );
            for (const [source, record] of [...sources]) {
              if (
                !record.dirty ||
                !source.matches?.(".bp-paper-edit-form[phx-change]")
              ) continue;
              clearTimeout(record.timer);
              record.timer = null;
              pending.push(record.active > 0 && record.pending
                ? record.pending
                : coordinator._sendFallback(source, driver));
            }

            if (!pending.length) return !coordinator.hasUnsaved(false);
            if (!(await Promise.all(pending)).every(Boolean)) return false;
          }
          return false;
        },
        async run(action) {
          if (actionPending) return false;
          actionPending = true;
          try {
            const saved = await coordinator.drain();
            if (!saved) return false;
            await action();
            return true;
          } finally {
            actionPending = false;
          }
        },
        requestId: bpPaperRequestId,
        mutate(source, {
          requestId, payload, send, onResult, reviewRequired = false,
          kind = "forward", trackDraft = true, historyDirection = null, historyStep = null,
        }) {
          requestId ||= bpPaperRequestId();
          if (!requestId) return { requestId: null, promise: Promise.resolve(false) };
          let entry = mutationById.get(requestId);
          if (!entry) {
            for (const [fallbackSource, fallbackRecord] of sources) {
              if (fallbackSource === source || !fallbackRecord.dirty ||
                  !fallbackSource.matches?.(".bp-paper-edit-form[phx-change]")) continue;
              clearTimeout(fallbackRecord.timer);
              fallbackRecord.timer = null;
              fallbackRecord.fallbackDeferred = true;
            }
            const record = trackDraft ? recordFor(source) : null;
            if (record && record.authoredRev === undefined) {
              record.authoredRev = authoredRevisionFor(source, record);
            }
            entry = {
              source, requestId, payload, send, onResult, reviewRequired, kind,
              trackDraft, historyDirection, historyStep,
              documentKey: record?.documentKey ?? documentKey,
              authoredRev: record?.authoredRev ?? confirmedRevision,
              ifRev: mutationQueue.length || (record?.documentKey ?? documentKey) !== documentKey
                ? undefined
                : record?.authoredRev ?? confirmedRevision,
              expiresAt: Date.now() + PAPER_OP_RETRY_TTL_MS,
              waiters: [],
            };
            mutationById.set(requestId, entry);
            mutationQueue.push(entry);
          }
          const promise = new Promise((resolve) => entry.waiters.push(resolve));
          mutationPaused = false;
          coordinator._pumpMutations();
          renderHistoryControls();
          return { requestId: entry.requestId, promise, entry };
        },
        retryMutation(entry) {
          if (!entry || mutationById.get(entry.requestId) !== entry || conflict) {
            return Promise.resolve(false);
          }
          if (Date.now() >= entry.expiresAt) {
            coordinator._expireMutation(entry);
            return Promise.resolve(false);
          }
          const promise = new Promise((resolve) => entry.waiters.push(resolve));
          mutationPaused = false;
          coordinator._pumpMutations();
          return promise;
        },
        observeRevision({
          rev, requestId, apply, observedDocumentKey, source, reloadOnLatest = false,
        }) {
          if (rev == null) return false;
          if (observedDocumentKey && observedDocumentKey !== documentKey) {
            if (!coordinator._hasUnsavedForDocument(documentKey) && !mutationQueue.length) {
              coordinator._resetIdentity({ key: observedDocumentKey, rev });
              apply?.("external");
              return true;
            }
            pendingIdentity = { key: observedDocumentKey, rev };
            quarantinedEchoes.push({
              rev, requestId, apply, documentKey: observedDocumentKey, reloadOnLatest,
            });
            return false;
          }
          if (requestId && ownRevisions.get(requestId) === rev) {
            apply?.(rev === confirmedRevision ? "own" : "own-stale");
            return true;
          }
          if (rev === confirmedRevision) {
            if (!coordinator.hasUnsaved()) apply?.("current");
            return true;
          }
          if (mutationQueue.length || coordinator.hasUnsaved()) {
            quarantinedEchoes.push({
              rev, requestId, apply, documentKey, reloadOnLatest, source,
            });
            if (!mutationActive && !reloadOnLatest) {
              for (const [fallbackSource, fallbackRecord] of sources) {
                if (!fallbackRecord.dirty ||
                    !fallbackSource.matches?.(".bp-paper-edit-form[phx-change]") ||
                    fallbackRecord.documentKey !== documentKey) continue;
                clearTimeout(fallbackRecord.timer);
                fallbackRecord.timer = null;
                fallbackRecord.fallbackDeferred = true;
                fallbackRecord.fallbackUnsafe = true;
              }
              coordinator._setConflict(
                {
                  current_rev: rev,
                  ...(reloadOnLatest
                    ? { fallback_unsafe: true, reload_on_latest: true }
                    : {}),
                },
                source,
                observedDocumentKey,
              );
            }
            if (!mutationActive && reloadOnLatest) {
              coordinator._reviewQuarantinedReloadConflict();
            }
            return false;
          }
          confirmedRevision = rev;
          apply?.("external");
          return true;
        },
      };

      coordinator._resolveWaiters = (entry, saved) => {
        const waiters = entry.waiters.splice(0);
        waiters.forEach((resolve) => resolve(saved));
      };
      coordinator._recordForwardHistory = (entry, reply) => {
        if (entry.kind === "history") return;
        if (reply?.changed !== false) contextualHistory.redo.length = 0;
        if (reply?.changed !== true) {
          renderHistoryControls();
          return;
        }
        const step = bpPaperContextualHistoryStep(reply.history_step, entry.requestId, "undo");
        if (step) pushHistory("undo", step);
        renderHistoryControls();
      };
      coordinator._settleHistory = (entry, replyStep) => {
        const source = historyStack(entry.historyDirection);
        const current = source.at(-1);
        if (!current || current !== entry.historyStep) return false;
        source.pop();
        const retainedFocusBaselines = new WeakMap();
        for (const [draftSource, record] of sources) {
          if (!record.dirty && record.active === 0) continue;
          const baseline = nativeFocusBaselines.get(draftSource);
          if (baseline) retainedFocusBaselines.set(draftSource, baseline);
        }
        nativeFocusBaselines = retainedFocusBaselines;
        pushHistory(replyStep.action, replyStep);
        renderHistoryControls();
        return true;
      };
      coordinator._terminalHistoryFailure = (entry, reply) => {
        if (entry.kind !== "history" || reply?.request_id !== entry.requestId) return false;
        const reason = reply?.rejected || reply?.error || reply?.code ||
          (reply?.conflict === true ? "history_conflict" : null);
        if (!["history_expired", "history_ref_expired", "idempotency_receipt_expired",
              "history_ref_consumed", "history_conflict", "history_unavailable",
              "invalid_history_request"].includes(reason)) return false;
        mutationQueue.shift();
        mutationById.delete(entry.requestId);
        if (historyTop(entry.historyDirection) === entry.historyStep) {
          entry.historyStep.disabledReason = reason;
        }
        mutationPaused = false;
        coordinator._notifyResult(entry, false, reply);
        coordinator._resolveWaiters(entry, false);
        renderHistoryControls();
        coordinator._pumpMutations();
        return true;
      };
      coordinator._requestHistory = (direction, source) => {
        const pending = historyPendingEntry();
        if (pending) {
          if (pending.historyDirection !== direction || mutationActive || conflict) return false;
          coordinator.retryMutation(pending);
          renderSaveStatus();
          renderHistoryControls();
          return true;
        }
        historyRequestPending = direction;
        renderSaveStatus();
        renderHistoryControls();
        Promise.resolve(coordinator.run(async () => {
          const step = historyTop(direction);
          if (!step || step.disabledReason) return false;
          if (Date.now() >= step.expiresAt) {
            step.disabledReason = "history_ref_expired";
            renderHistoryControls();
            return false;
          }
          const driver = [...members].find((member) => typeof member.pushEvent === "function");
          if (!driver) return false;
          const mutation = bpPaperMutation(
            driver,
            source,
            "paper-history-step",
            { history_ref: step.ref, action: step.action },
            {
              requestId: step.requestId,
              kind: "history",
              trackDraft: false,
              historyDirection: direction,
              historyStep: step,
            },
          );
          renderHistoryControls();
          return mutation.promise;
        })).finally(() => {
          historyRequestPending = null;
          renderSaveStatus(false);
          renderHistoryControls();
        });
        return true;
      };
      coordinator._notifyResult = (entry, saved, result) => {
        try {
          entry.onResult?.(saved, result);
        } catch (error) {
          // Mutation settlement owns the document queue. A canvas/native adapter
          // failure must not strand later form drafts or navigation waiters.
          const message = "Mutation result could not be applied by its local editor adapter.";
          try {
            console.error(message, error);
          } catch (_) {}
          try {
            entry.source?.dispatchEvent?.(new CustomEvent("bp-error", {
              detail: { code: "paper_mutation_result_callback_failed", error: message },
              bubbles: true,
              composed: true,
            }));
          } catch (_) {}
        }
      };
      coordinator._pauseFallbackForReview = (source, record, entry = null) => {
        clearTimeout(record.timer);
        record.timer = null;
        record.fallbackDeferred = true;
        record.fallbackUnsafe = true;
        if (!conflict) coordinator._setConflict(
          { current_rev: confirmedRevision, fallback_unsafe: true },
          source,
          record.documentKey,
          entry,
        );
      };
      coordinator._resumeFallbackDrafts = () => {
        const deferred = [...sources].filter(([source, record]) =>
          record.fallbackDeferred && record.dirty && record.active === 0 &&
          !record.mutationEntry && source.isConnected &&
          source.matches?.(".bp-paper-edit-form[phx-change]") &&
          record.documentKey === documentKey);
        const unsafe = deferred.find(([_source, record]) =>
          record.fallbackUnsafe || record.authoredRev !== confirmedRevision);
        if (unsafe) {
          coordinator._pauseFallbackForReview(unsafe[0], unsafe[1]);
          return false;
        }
        if (conflict || mutationQueue.length) return false;
        deferred.forEach(([source, record]) => {
          record.fallbackDeferred = false;
          coordinator._scheduleFallback(source);
        });
        return true;
      };
      coordinator._advanceFallbackDrafts = (entry) => {
        let unsafe = null;
        for (const [source, record] of sources) {
          if (!record.fallbackDeferred || !record.dirty || record.active > 0 ||
              record.mutationEntry ||
              !source.matches?.(".bp-paper-edit-form[phx-change]") ||
              record.documentKey !== entry.documentKey) continue;
          if (!source.isConnected &&
              detachedReferenceDrafts.some((draft) => draft.source === source)) {
            // The old identity has no live form to restore or save. Its exact
            // captured value remains recovery-owned until explicit discard.
            record.fallbackDeferred = false;
            record.fallbackUnsafe = false;
            continue;
          }
          if (source === entry.source && bpPaperPositionalCollectionActionEntry(entry)) {
            coordinator._pauseFallbackForReview(source, record, entry);
            unsafe ||= [source, record, entry];
            continue;
          }
          const snapshot = record.formSnapshot;
          const currentIdentity = identityFor(source);
          const carrierRevisionIsOwn = currentIdentity.rev === snapshot?.documentRevision ||
            currentIdentity.rev === confirmedRevision;
          const externalRevisionPending = quarantinedEchoes.some((echo) =>
            (!echo.documentKey || echo.documentKey === entry.documentKey) &&
            echo.rev !== confirmedRevision);
          if (!snapshot || record.authoredRev !== entry.ifRev ||
              currentIdentity.key !== snapshot.documentKey || !carrierRevisionIsOwn ||
              externalRevisionPending) {
            coordinator._pauseFallbackForReview(source, record);
            unsafe ||= [source, record, null];
            continue;
          }
          const advancedSnapshot = {
            ...snapshot,
            documentRevision: currentIdentity.rev,
          };
          if (!bpPaperRestoreFallbackForm(
            advancedSnapshot,
            source,
            currentIdentity,
            main,
          )) {
            coordinator._pauseFallbackForReview(source, record);
            unsafe ||= [source, record, null];
            continue;
          }
          record.formSnapshot = advancedSnapshot;
          record.authoredRev = confirmedRevision;
          record.documentRevision = currentIdentity.rev;
          record.fallbackUnsafe = false;
        }
        if (!unsafe) coordinator._resumeFallbackDrafts();
      };
      coordinator._hasUnsavedForDocument = (key) => {
        if (detachedReferenceDrafts.some((draft) => draft.documentKey === key)) return true;
        for (const record of sources.values()) {
          if (record.documentKey === key && (record.dirty || record.active > 0)) return true;
        }
        return false;
      };
      coordinator._resetIdentity = ({ key, rev }) => {
        documentKey = key || null;
        confirmedRevision = rev ?? null;
        nativeFocusBaselines = new WeakMap();
        ownRevisions.clear();
        quarantinedEchoes.length = 0;
        contextualHistory.undo.length = 0;
        contextualHistory.redo.length = 0;
        historyRequestPending = null;
        conflict = null;
        mutationPaused = false;
        coordinator._renderConflict?.();
        renderHistoryControls();
      };
      coordinator._maybeAdoptPendingIdentity = () => {
        if (!pendingIdentity || coordinator._hasUnsavedForDocument(documentKey) ||
            mutationQueue.some((entry) => entry.documentKey === documentKey)) return false;
        const next = pendingIdentity;
        pendingIdentity = null;
        coordinator._resetIdentity(next);
        return true;
      };
      coordinator._flushQuarantinedIfClean = () => {
        if (mutationQueue.some((entry) => entry.documentKey === documentKey) ||
            coordinator._hasUnsavedForDocument(documentKey)) return false;
        const candidates = quarantinedEchoes.filter((echo) =>
          !echo.documentKey || echo.documentKey === documentKey,
        );
        if (!candidates.length) return false;
        const newest = candidates[candidates.length - 1];
        const latest = candidates.filter((echo) => echo.rev === newest.rev);
        for (let i = quarantinedEchoes.length - 1; i >= 0; i--) {
          if (!quarantinedEchoes[i].documentKey ||
              quarantinedEchoes[i].documentKey === documentKey) {
            quarantinedEchoes.splice(i, 1);
          }
        }
        confirmedRevision = newest.rev;
        latest.forEach((echo) => echo.apply?.("external"));
        return true;
      };
      coordinator._reviewQuarantinedReloadConflict = () => {
        const echo = quarantinedEchoes.findLast((candidate) =>
          candidate.reloadOnLatest &&
          (!candidate.documentKey || candidate.documentKey === documentKey));
        if (mutationActive || !echo) return false;
        if (conflict?.reloadOnLatest) {
          conflict.currentRev = echo.rev;
          conflict.reply = { ...conflict.reply, current_rev: echo.rev };
          coordinator._renderConflict();
          return true;
        }
        if (conflict) return false;
        if (!mutationQueue.length && !coordinator.hasUnsaved()) return false;
        for (const [fallbackSource, fallbackRecord] of sources) {
          if (!fallbackRecord.dirty ||
              !fallbackSource.matches?.(".bp-paper-edit-form[phx-change]") ||
              fallbackRecord.documentKey !== documentKey) continue;
          clearTimeout(fallbackRecord.timer);
          fallbackRecord.timer = null;
          fallbackRecord.fallbackDeferred = true;
          fallbackRecord.fallbackUnsafe = true;
        }
        coordinator._setConflict(
          {
            current_rev: echo.rev,
            fallback_unsafe: true,
            reload_on_latest: true,
          },
          echo.source,
          echo.documentKey,
        );
        return true;
      };
      coordinator._reloadIfClean = () => {
        if (!reloadWhenClean || mutationActive || mutationQueue.length ||
            coordinator.hasUnsaved()) return false;
        reloadWhenClean = false;
        window.location.reload();
        return true;
      };
      coordinator._expireMutation = (entry) => {
        if (entry.kind === "history") {
          mutationQueue.shift();
          mutationById.delete(entry.requestId);
          if (historyTop(entry.historyDirection) === entry.historyStep) {
            entry.historyStep.disabledReason = "history_ref_expired";
          }
          mutationPaused = false;
          coordinator._notifyResult(entry, false, {
            saved: false,
            request_id: entry.requestId,
            rejected: "history_ref_expired",
          });
          coordinator._resolveWaiters(entry, false);
          renderHistoryControls();
          coordinator._pumpMutations();
          return;
        }
        mutationPaused = true;
        const message = "Save paused after one hour of retries. Unsaved work remains here; copy it before reloading.";
        const status = main.querySelector('[data-test-id="bp-paper-footer-save"][role="status"]');
        if (status) status.textContent = message;
        if (entry.expiryReported) return;
        entry.expiryReported = true;
        entry.source?.dispatchEvent?.(new CustomEvent("bp-error", {
          detail: { code: "paper_mutation_retry_expired", error: message },
          bubbles: true,
          composed: true,
        }));
      };
      coordinator._detachedReferenceDraftIsLocalOnly = (draft) => {
        const record = draft && sources.get(draft.source);
        return Boolean(record && record.dirty && record.active === 0 &&
          record.documentKey === draft.documentKey && draft.documentKey === documentKey &&
          !draft.source.isConnected &&
          record.pending == null && record.mutationEntry == null &&
          !mutationQueue.some((entry) => entry.source === draft.source));
      };
      coordinator._blockingDetachedReferenceDraft = (key = conflict?.documentKey) =>
        detachedReferenceDrafts.find((draft) =>
          draft.documentKey === key &&
          !coordinator._detachedReferenceDraftIsLocalOnly(draft),
        ) || null;
      coordinator._conflictDetachedReferenceDraft = () =>
        detachedReferenceDrafts.find((draft) => draft.source === conflict?.source) ||
        coordinator._blockingDetachedReferenceDraft();
      coordinator._removeDetachedReferenceDraft = (source) => {
        const index = detachedReferenceDrafts.findIndex((draft) => draft.source === source);
        if (index < 0) return false;
        detachedReferenceDrafts.splice(index, 1);
        coordinator._renderDetachedReferenceDraft();
        return true;
      };
      coordinator._downloadDetachedReferenceDraft = (draft) => {
        if (!draft || !detachedReferenceDrafts.includes(draft)) return false;
        const bundle = {
          format: "barkpark-paper-field-recovery",
          version: 1,
          scope: "detached-reference-field",
          notice: "Recovery bundle for one replaced related-Paper field; not a complete Paper document export.",
          document: {
            key: draft.documentKey,
            ...(draft.snapshot.identity.documentRevision != null
              ? { revision: draft.snapshot.identity.documentRevision }
              : {}),
          },
          draft: draft.snapshot,
        };
        const blob = new window.Blob([`${JSON.stringify(bundle, null, 2)}\n`], {
          type: "application/json",
        });
        const href = window.URL.createObjectURL(blob);
        const download = document.createElement("a");
        const safeKey = draft.documentKey.replace(/[^a-zA-Z0-9._-]+/g, "-")
          .slice(0, 120) || "paper";
        download.href = href;
        download.download = `${safeKey}-reference-draft-recovery.json`;
        download.click();
        Promise.resolve().then(() => window.URL.revokeObjectURL(href));
        return true;
      };
      coordinator._discardDetachedReferenceDraft = (draft, conflictOwned = false) => {
        const draftIndex = detachedReferenceDrafts.indexOf(draft);
        if (!draft || draftIndex < 0 ||
            (!conflictOwned && draftIndex !== 0) ||
            (conflictOwned && conflict?.source !== draft.source) ||
            !coordinator._detachedReferenceDraftIsLocalOnly(draft)) return false;
        const record = sources.get(draft.source);
        clearTimeout(record.timer);
        record.timer = null;
        // Recheck after cancelling the never-fired debounce. Any request entry,
        // active send or retained promise keeps this recovery export-only.
        if (!coordinator._detachedReferenceDraftIsLocalOnly(draft)) return false;
        sources.delete(draft.source);
        nativeFocusBaselines.delete(draft.source);
        detachedReferenceDrafts.splice(draftIndex, 1);
        coordinator._renderDetachedReferenceDraft();
        renderSaveStatus();
        if (conflictOwned) return true;
        if (!coordinator._maybeAdoptPendingIdentity()) {
          coordinator._flushQuarantinedIfClean();
        }
        coordinator._resumeFallbackDrafts();
        coordinator._pumpMutations();
        // Do not request a reload here, but honor one already requested by an
        // independent recovery boundary once this last local draft is gone.
        coordinator._reloadIfClean();
        return true;
      };
      coordinator._discardConflictDetachedReferenceDraft = (draft) => {
        if (!draft || conflict?.source !== draft.source ||
            !coordinator._detachedReferenceDraftIsLocalOnly(draft)) return false;
        const retainedReply = conflict.reply;
        const retainedDocumentKey = conflict.documentKey;
        if (!coordinator._discardDetachedReferenceDraft(draft, true)) return false;
        const nextDraft = detachedReferenceDrafts.find(
          (candidate) => candidate.documentKey === retainedDocumentKey,
        );
        const nextEntry = nextDraft
          ? mutationQueue.find((entry) =>
            entry.documentKey === retainedDocumentKey && entry.source === nextDraft.source,
          )
          : mutationQueue.find((entry) => entry.documentKey === retainedDocumentKey);
        const nextDirty = [...sources].find(([source, record]) =>
          record.documentKey === retainedDocumentKey &&
          (record.dirty || record.active > 0) &&
          (!nextDraft || source === nextDraft.source),
        ) || [...sources].find(([_source, record]) =>
          record.documentKey === retainedDocumentKey &&
          (record.dirty || record.active > 0),
        );
        const nextSource = nextDraft?.source || nextEntry?.source || nextDirty?.[0];
        if (nextSource || nextEntry || mutationActive) {
          coordinator._setConflict(
            retainedReply,
            nextSource || nextEntry?.source,
            retainedDocumentKey,
            nextEntry || null,
          );
          return true;
        }
        coordinator._useLatest();
        return true;
      };
      coordinator._renderDetachedReferenceDraft = () => {
        let banner = main.querySelector("[data-bp-paper-reference-draft]");
        const draft = detachedReferenceDrafts[0];
        if (!draft || conflict) {
          banner?.remove();
          return;
        }
        if (!banner) {
          banner = document.createElement("div");
          banner.dataset.bpPaperConflict = "true";
          banner.dataset.bpPaperReferenceDraft = "true";
          banner.setAttribute("role", "alert");
          banner.innerHTML = '<strong class="bp-conflict-title">Related Paper changed</strong><span class="bp-conflict-description"></span><div class="bp-conflict-actions"><button type="button" data-action="review" aria-expanded="false">Review retained draft</button><button type="button" data-action="keep" disabled aria-disabled="true">Keep mine</button><button type="button" data-reference-draft-download>Download old field draft</button><button type="button" data-reference-draft-discard>Discard old draft</button></div><div data-conflict-detail hidden><p data-conflict-message></p><label><span data-reference-draft-label></span><textarea data-reference-draft-text readonly></textarea></label><details><summary>Technical details</summary><pre data-conflict-draft aria-label="Unsaved draft payload" tabindex="0"></pre></details></div>';
          const root = main.querySelector(".bp-paper-editor") || main;
          root.prepend(banner);
          banner.addEventListener("click", (event) => {
            const current = detachedReferenceDrafts[0];
            if (!current) return;
            if (event.target.closest?.('[data-action="review"]')) {
              const detail = banner.querySelector("[data-conflict-detail]");
              detail.hidden = false;
              banner.querySelector('[data-action="review"]')
                .setAttribute("aria-expanded", "true");
            } else if (event.target.closest?.("[data-reference-draft-download]")) {
              coordinator._downloadDetachedReferenceDraft(current);
            } else if (event.target.closest?.("[data-reference-draft-discard]")) {
              coordinator._discardDetachedReferenceDraft(current);
            }
          });
        }
        const localOnly = coordinator._detachedReferenceDraftIsLocalOnly(draft);
        const fieldLabel = draft.field === "title" ? "title" : "description";
        banner.querySelector(".bp-conflict-description").textContent = localOnly
          ? `This related Paper was replaced before your ${fieldLabel} draft was sent. The draft was not applied to the replacement.`
          : `This related Paper was replaced while your ${fieldLabel} save was unresolved. Download the retained draft while its result is confirmed.`;
        banner.querySelector("[data-conflict-message]").textContent = localOnly
          ? "Download or copy this exact draft before explicitly discarding it."
          : "This save may already have reached the server. It cannot be discarded safely here.";
        banner.querySelector("[data-reference-draft-label]").textContent =
          `Retained ${fieldLabel} draft`;
        banner.querySelector("[data-reference-draft-text]").value = draft.value;
        banner.querySelector("[data-conflict-draft]").textContent =
          JSON.stringify(draft.snapshot, null, 2);
        const discard = banner.querySelector("[data-reference-draft-discard]");
        discard.disabled = !localOnly;
        discard.setAttribute("aria-disabled", String(!localOnly));
        discard.title = localOnly
          ? ""
          : "This save has an unresolved server outcome and cannot be discarded here.";
      };
      coordinator._setConflict = (reply, source, sourceDocumentKey, conflictEntry = null) => {
        const dirtyFallbackSource = [...sources].find(([fallbackSource, record]) =>
          record.dirty && fallbackSource.matches?.(".bp-paper-edit-form[phx-change]") &&
          record.documentKey === (sourceDocumentKey || documentKey))?.[0];
        const sourceRecord = sources.get(source);
        const sourceHasDraft = sourceRecord && (sourceRecord.dirty || sourceRecord.active > 0);
        const conflictSource = conflictEntry?.source ||
          (sourceHasDraft ? source : null) || mutationQueue[0]?.source ||
          dirtyFallbackSource || source;
        const entry = conflictEntry ||
          mutationQueue.find((queued) => queued.source === conflictSource) ||
          mutationQueue[0] || null;
        const snapshot = sources.get(conflictSource)?.formSnapshot;
        const positional = bpPaperPositionalCollectionEntry(entry) ||
          bpPaperPositionalCollectionActionEntry(entry) ||
          snapshot?.countValues?.some(([name]) => PAPER_POSITIONAL_COLLECTION_PARAM.test(name)) === true;
        conflict = {
          currentRev: reply?.current_rev,
          reply,
          source: conflictSource,
          documentKey: sourceDocumentKey || conflictEntry?.documentKey ||
            mutationQueue[0]?.documentKey || documentKey,
          entry,
          snapshot,
          latestSnapshot: null,
          positional,
          keepUnavailable: reply?.fallback_unsafe === true || positional || !entry,
          reloadOnLatest: reply?.reload_on_latest === true,
        };
        mutationPaused = true;
        coordinator._renderConflict();
        renderSaveStatus();
      };
      coordinator._renderConflict = () => {
        let banner = main.querySelector(
          "[data-bp-paper-conflict]:not([data-bp-paper-reference-draft])",
        );
        if (!conflict) {
          banner?.remove();
          coordinator._renderDetachedReferenceDraft();
          return;
        }
        main.querySelector("[data-bp-paper-reference-draft]")?.remove();
        const renderDetail = (notify = false) => {
          const detail = banner.querySelector("[data-conflict-detail]");
          const head = conflict.entry;
          const positional = conflict.positional;
          detail.hidden = false;
          banner.querySelector('[data-action="review"]').setAttribute("aria-expanded", "true");
          detail.querySelector("[data-conflict-message]").textContent = positional
            ? `Server revision ${String(conflict.currentRev ?? "unknown")}. Row positions may have changed. Keep mine is unavailable for positional collections; Use latest explicitly discards this draft.`
            : conflict.keepUnavailable
              ? `Server revision ${String(conflict.currentRev ?? "unknown")}. No exact retry payload is available. Use latest explicitly discards this retained draft.`
              : `Server revision ${String(conflict.currentRev ?? "unknown")}. Keep mine retries your edits on that revision; Use latest discards them.`;
          const retainedDraft = bpPaperConflictDraft(head, conflict.snapshot);
          const reviewDraft = conflict.latestSnapshot
            ? {
                retainedDraftBeforeAcknowledgement: retainedDraft,
                currentDraftDuringReview: bpPaperConflictDraft(head, conflict.latestSnapshot),
              }
            : retainedDraft;
          detail.querySelector("[data-conflict-draft]").textContent =
            JSON.stringify(reviewDraft, null, 2);
          if (notify) {
            main.dispatchEvent(new CustomEvent("bp-paper-conflict-review", {
              detail: { documentKey, conflict: conflict.reply }, bubbles: true,
            }));
          }
        };
        if (!banner) {
          banner = document.createElement("div");
          banner.dataset.bpPaperConflict = "true";
          banner.setAttribute("role", "alert");
          banner.innerHTML = '<strong class="bp-conflict-title">Save paused</strong><span class="bp-conflict-description">This document changed elsewhere. Your edits are still here.</span><div class="bp-conflict-actions"><button type="button" data-action="review" aria-expanded="false">Review</button><button type="button" data-action="keep">Keep mine</button><button type="button" data-action="latest">Use latest</button></div><div data-conflict-detail hidden><p data-conflict-message></p><details><summary>Technical details</summary><pre data-conflict-draft aria-label="Unsaved draft payload" tabindex="0"></pre></details></div>';
          const root = main.querySelector(".bp-paper-editor") || main;
          root.prepend(banner);
          banner.addEventListener("click", (event) => {
            const detached = coordinator._conflictDetachedReferenceDraft();
            if (event.target.closest?.("[data-reference-draft-download]") && detached) {
              coordinator._downloadDetachedReferenceDraft(detached);
              return;
            }
            if (event.target.closest?.("[data-reference-draft-discard]") &&
                detached?.source === conflict?.source &&
                coordinator._detachedReferenceDraftIsLocalOnly(detached)) {
              coordinator._discardConflictDetachedReferenceDraft(detached);
              return;
            }
            const action = event.target.closest?.("[data-action]")?.dataset.action;
            if (action === "review") {
              renderDetail(true);
            } else if (action === "keep") {
              coordinator._keepMine();
            } else if (action === "latest") {
              coordinator._useLatest();
            }
          });
        }
        const keepUnavailable = conflict.keepUnavailable;
        const keep = banner.querySelector('[data-action="keep"]');
        keep.disabled = keepUnavailable;
        keep.setAttribute("aria-disabled", String(keepUnavailable));
        keep.title = keepUnavailable ? "This retained draft has no safe exact rebase path." : "";
        const detached = coordinator._conflictDetachedReferenceDraft();
        if (detached) {
          keep.disabled = true;
          keep.setAttribute("aria-disabled", "true");
          let download = banner.querySelector("[data-reference-draft-download]");
          if (!download) {
            download = document.createElement("button");
            download.type = "button";
            download.dataset.referenceDraftDownload = "true";
            download.dataset.detachedReferenceRecovery = "true";
            download.textContent = "Download old field draft";
            banner.querySelector(".bp-conflict-actions")?.append(download);
          }
          const latest = banner.querySelector('[data-action="latest"]');
          latest.disabled = true;
          latest.setAttribute("aria-disabled", "true");
          latest.title = "This save has an unresolved server outcome and cannot be discarded here.";
          const detail = banner.querySelector("[data-conflict-detail]");
          let field = detail.querySelector("[data-reference-draft-text]");
          if (!field) {
            const label = document.createElement("label");
            label.dataset.detachedReferenceRecovery = "true";
            const labelText = document.createElement("span");
            labelText.dataset.referenceDraftLabel = "true";
            field = document.createElement("textarea");
            field.dataset.referenceDraftText = "true";
            field.readOnly = true;
            label.append(labelText, field);
            detail.querySelector("details")?.before(label);
          }
          detail.querySelector("[data-reference-draft-label]").textContent =
            `Retained ${detached.field} draft`;
          field.value = detached.value;
          const canDiscard = detached.source === conflict.source &&
            coordinator._detachedReferenceDraftIsLocalOnly(detached);
          let discard = banner.querySelector("[data-reference-draft-discard]");
          if (canDiscard && !discard) {
            discard = document.createElement("button");
            discard.type = "button";
            discard.dataset.referenceDraftDiscard = "true";
            discard.dataset.detachedReferenceRecovery = "true";
            discard.textContent = "Discard old draft";
            banner.querySelector(".bp-conflict-actions")?.append(discard);
          } else if (!canDiscard) {
            discard?.remove();
          }
        } else {
          banner.querySelectorAll("[data-detached-reference-recovery]").forEach(
            (element) => element.remove(),
          );
          const latest = banner.querySelector('[data-action="latest"]');
          latest.disabled = false;
          latest.setAttribute("aria-disabled", "false");
          latest.title = "";
        }
        const openDetail = banner.querySelector("[data-conflict-detail]:not([hidden])");
        if (openDetail) renderDetail();
      };
      coordinator._keepMine = () => {
        const head = mutationQueue[0];
        if (coordinator._conflictDetachedReferenceDraft()) {
          return false;
        }
        if (!head || conflict?.currentRev == null || conflict.keepUnavailable) {
          return false;
        }
        const replacementId = bpPaperRequestId();
        if (!replacementId) return false;
        mutationById.delete(head.requestId);
        head.requestId = replacementId;
        head.ifRev = conflict.currentRev;
        head.reviewRequired = false;
        mutationById.set(head.requestId, head);
        confirmedRevision = conflict.currentRev;
        conflict = null;
        mutationPaused = false;
        coordinator._renderConflict();
        coordinator._pumpMutations();
        return true;
      };
      coordinator._useLatest = () => {
        const chosenSource = conflict?.source;
        if (coordinator._conflictDetachedReferenceDraft()) {
          return false;
        }
        const chosenRecord = sources.get(chosenSource);
        const reloadBoundary = conflict?.reloadOnLatest
          ? chosenSource?.closest?.("[data-paper-terminal-boundary]")
          : null;
        const requiresReload = Boolean(
          conflict?.reloadOnLatest ||
          (chosenRecord &&
            !chosenSource.matches?.('[phx-hook="BarkparkPaperCanvas"], [phx-hook="BarkparkPaperEditor"]')),
        );
        const latestRevision = conflict?.currentRev ?? quarantinedEchoes.at(-1)?.rev;
        const latest = quarantinedEchoes.filter((echo) =>
          echo.rev === latestRevision &&
          (!echo.documentKey || echo.documentKey === conflict?.documentKey),
        );
        for (let index = mutationQueue.length - 1; index >= 0; index--) {
          const entry = mutationQueue[index];
          if (entry.source !== chosenSource) continue;
          mutationQueue.splice(index, 1);
          mutationById.delete(entry.requestId);
          coordinator._notifyResult(entry, false, { discarded: true });
          coordinator._resolveWaiters(entry, false);
        }
        if (reloadBoundary) bpPaperDiscardPendingSource(chosenSource);
        sources.delete(chosenSource);
        const retainedReloadReply = conflict?.reply;
        const retainedDocumentKey = conflict?.documentKey;
        conflict = null;
        mutationPaused = false;
        const nextReloadSource = reloadBoundary && coordinator.firstUnsavedWithin(reloadBoundary);
        if (nextReloadSource) {
          coordinator._setConflict(
            {
              ...retainedReloadReply,
              current_rev: latestRevision,
              fallback_unsafe: true,
              reload_on_latest: true,
            },
            nextReloadSource,
            retainedDocumentKey,
          );
          return false;
        }
        const nextReloadEcho = reloadBoundary && [...quarantinedEchoes].reverse().find((echo) => {
          if (!echo.reloadOnLatest ||
              (echo.documentKey && echo.documentKey !== retainedDocumentKey)) return false;
          const boundary = echo.source?.closest?.("[data-paper-terminal-boundary]");
          return boundary && boundary !== reloadBoundary &&
            coordinator.firstUnsavedWithin(boundary);
        });
        if (nextReloadEcho) {
          const boundary = nextReloadEcho.source.closest("[data-paper-terminal-boundary]");
          coordinator._setConflict(
            {
              current_rev: nextReloadEcho.rev,
              fallback_unsafe: true,
              reload_on_latest: true,
            },
            coordinator.firstUnsavedWithin(boundary),
            nextReloadEcho.documentKey || retainedDocumentKey,
          );
          return false;
        }
        let replacedChosenSource = false;
        if (latestRevision != null) {
          confirmedRevision = latestRevision;
          if (!reloadBoundary) latest.forEach((echo) => {
            if (typeof echo.apply !== "function") return;
            echo.apply("external-resync");
            if (echo.source === chosenSource) replacedChosenSource = true;
          });
        }
        for (let index = quarantinedEchoes.length - 1; index >= 0; index--) {
          const echo = quarantinedEchoes[index];
          if (!echo.documentKey || echo.documentKey === documentKey) {
            quarantinedEchoes.splice(index, 1);
          }
        }
        mutationQueue.forEach((entry) => {
          if (entry.documentKey === documentKey) entry.ifRev = undefined;
        });
        if (requiresReload) reloadWhenClean = true;
        coordinator._renderConflict();
        coordinator._maybeAdoptPendingIdentity();
        coordinator._resumeFallbackDrafts();
        if (conflict) {
          coordinator._reloadIfClean();
          return;
        }
        // Only an applied replacement with no other retained work resolves the
        // authoritative failure. A revision number alone is not remote content;
        // another source may own a terminal warning without a queued mutation.
        if (replacedChosenSource && !coordinator.hasUnsaved() &&
            !mutationActive && !mutationQueue.length) {
          setSaveStatus("", true);
          renderSaveStatus();
        }
        coordinator._pumpMutations();
        coordinator._reloadIfClean();
      };
      coordinator._pumpMutations = () => {
        if (mutationActive || mutationPaused || conflict || !mutationQueue.length) return;
        const entry = mutationQueue[0];
        if (entry.documentKey && entry.documentKey !== documentKey) {
          if (coordinator._hasUnsavedForDocument(documentKey)) return;
          coordinator._resetIdentity({ key: entry.documentKey, rev: entry.authoredRev });
          pendingIdentity = null;
        }
        if (Date.now() >= entry.expiresAt) {
          coordinator._expireMutation(entry);
          coordinator._resolveWaiters(entry, false);
          return;
        }
        if (entry.reviewRequired) {
          const review = { current_rev: confirmedRevision, local_overlap: true };
          coordinator._setConflict(review, entry.source, entry.documentKey, entry);
          coordinator._notifyResult(entry, false, review);
          mutationQueue.forEach((queued) => coordinator._resolveWaiters(queued, false));
          return;
        }
        if (entry.ifRev === undefined) entry.ifRev = confirmedRevision;
        const wire = { ...entry.payload, request_id: entry.requestId };
        if (entry.ifRev != null) wire.if_rev = entry.ifRev;
        const token = entry.trackDraft === false ? null : coordinator.beginSave(entry.source);
        if (token && entry.source.matches?.(".bp-paper-edit-form[phx-change]")) {
          entry.formVersion ??= token.version;
          token.version = entry.formVersion;
        }
        mutationActive = true;
        let sent;
        try {
          sent = entry.send(wire);
        } catch (_) {
          sent = null;
        }
        Promise.resolve(sent).catch(() => null).then((reply) => {
          const identityOK = reply?.request_id === entry.requestId;
          const revOK = entry.ifRev == null || reply?.rev != null;
          const expectedHistoryAction = entry.historyDirection === "undo" ? "redo" : "undo";
          const replyHistoryStep = entry.kind === "history"
            ? bpPaperContextualHistoryStep(
                reply?.history_step,
                entry.requestId,
                expectedHistoryAction,
              )
            : null;
          const saved = reply?.saved === true && identityOK && revOK &&
            (entry.kind !== "history" || Boolean(replyHistoryStep));
          mutationActive = false;
          coordinator.finishSave(token, saved);
          if (!saved && coordinator._terminalHistoryFailure(entry, reply)) {
            renderSaveStatus(false);
            return;
          }
          if (saved) {
            confirmedRevision = reply.rev ?? confirmedRevision;
            const focused = nativeFocusBaselines.get(entry.source);
            if (focused?.key === entry.documentKey) focused.rev = confirmedRevision;
            ownRevisions.set(entry.requestId, confirmedRevision);
            mutationQueue.shift();
            mutationById.delete(entry.requestId);
            if (entry.kind === "history") {
              coordinator._settleHistory(entry, replyHistoryStep);
            } else {
              coordinator._recordForwardHistory(entry, reply);
            }
            if (!sources.has(entry.source)) {
              coordinator._removeDetachedReferenceDraft(entry.source);
            }
            const continuingSource = sources.get(entry.source);
            if (continuingSource?.dirty &&
                continuingSource.documentKey === entry.documentKey &&
                !entry.source.matches?.(".bp-paper-edit-form[phx-change]")) {
              // Canvas/native adapters may synchronously enqueue work retained
              // behind this exact batch from onResult. Give only that same source
              // the acknowledged base before its adapter creates the next entry.
              continuingSource.authoredRev = confirmedRevision;
            }
            coordinator._notifyResult(entry, true, reply);
            coordinator._resolveWaiters(entry, true);
            for (let i = quarantinedEchoes.length - 1; i >= 0; i--) {
              const echo = quarantinedEchoes[i];
              if ((echo.requestId === entry.requestId ||
                   (!echo.reloadOnLatest && echo.rev === confirmedRevision)) &&
                  (!echo.documentKey || echo.documentKey === documentKey)) {
                quarantinedEchoes.splice(i, 1);
                echo.apply?.("own");
              }
            }
            coordinator._reviewQuarantinedReloadConflict();
            if (!conflict) {
              advanceFocusedReferenceCopySibling(entry);
              coordinator._advanceFallbackDrafts(entry);
            }
            if (!coordinator._maybeAdoptPendingIdentity()) {
              coordinator._flushQuarantinedIfClean();
            }
            coordinator._pumpMutations();
            coordinator._reloadIfClean();
          } else {
            const validationReply =
              reply?.saved === false && reply?.request_id === entry.requestId &&
              reply?.rejected === "validation";
            const outdatedCanvasReply =
              reply?.saved === false && reply?.request_id === entry.requestId &&
              ["outdated_terminal_canvas", "outdated_stage_canvas"].includes(reply?.rejected);
            const matchingValidationRevision =
              validationReply && reply.current_rev === entry.ifRev;
            const record = sources.get(entry.source);
            const currentIdentity = identityFor(entry.source);
            const unchangedRevisionBase = matchingValidationRevision &&
              record?.formSnapshot?.documentRevision === entry.ifRev &&
              currentIdentity.rev === entry.ifRev && confirmedRevision === entry.ifRev &&
              !quarantinedEchoes.some((echo) =>
                (!echo.documentKey || echo.documentKey === entry.documentKey) &&
                echo.rev !== entry.ifRev);
            const restored = unchangedRevisionBase &&
              entry.source.matches?.(".bp-paper-edit-form[phx-change]") &&
              bpPaperRestoreFallbackForm(
                record?.formSnapshot,
                entry.source,
                currentIdentity,
                main,
              );
            coordinator._notifyResult(entry, false, reply);
            if (restored && mutationQueue[0] === entry) {
              const newerVersion = record?.version > (entry.formVersion ?? record.version);
              mutationQueue.shift();
              mutationById.delete(entry.requestId);
              if (record?.mutationEntry === entry) record.mutationEntry = null;
              coordinator._resolveWaiters(entry, false);
              mutationPaused = true;
              if (newerVersion) coordinator._scheduleFallback(entry.source);
            } else if (validationReply || outdatedCanvasReply) {
              mutationQueue.forEach((queued) => coordinator._resolveWaiters(queued, false));
              coordinator._setConflict(
                {
                  ...reply,
                  conflict: true,
                  ...(outdatedCanvasReply
                    ? { fallback_unsafe: true, reload_on_latest: true }
                    : {}),
                },
                entry.source,
                entry.documentKey,
              );
            } else {
              mutationQueue.forEach((queued) => coordinator._resolveWaiters(queued, false));
              if (reply?.conflict === true && reply?.request_id === entry.requestId) {
                coordinator._setConflict(reply);
              } else {
                mutationPaused = true;
              }
            }
            coordinator._reviewQuarantinedReloadConflict();
          }
          renderSaveStatus(saved);
          renderHistoryControls();
        });
      };

      coordinator._onNativeFocus = (event) => {
        const source = nativeFormFor(event.target);
        if (!source || !main.contains(source) || !main.contains(event.target)) return;
        const identity = identityFor(source);
        if (nativeFocusBaselines.get(source)?.key !== identity.key) {
          nativeFocusBaselines.set(source, {
            key: identity.key,
            rev: identity.key === documentKey ? confirmedRevision : identity.rev,
          });
        }
      };
      coordinator._onNativeBlur = (event) => {
        const source = nativeFormFor(event.target);
        const focused = source && nativeFocusBaselines.get(source);
        const record = source && sources.get(source);
        // A remote repaint may have skipped the focused value. Retain its
        // original revision even after blur; that stale value remains in the
        // form until an acknowledged save or authoritative remount replaces it.
        if (focused?.key === documentKey && focused.rev === confirmedRevision &&
            !record?.dirty && !record?.active) nativeFocusBaselines.delete(source);
      };
      coordinator._onInput = (event) => {
        const target = event.target;
        if (target.closest?.(
          'bp-paper-editor[data-editor-mode="card-body"], bp-paper-editor[data-editor-mode="table"]',
        )) return;
        const associatedForm = nativeFormFor(target);
        const source = target.closest?.("form[data-paper-field-flush]") ||
          target.closest?.(PAPER_FLUSH_TARGETS) ||
          target.closest?.(".bp-paper-edit-form[phx-change]") || associatedForm;
        if (!source || !main.contains(source)) return;
        // Fallback forms can receive newer input while an older snapshot is
        // saving. Advance their dirty version so that acknowledgement cannot
        // clear the newer edit or let View discard it.
        if (sources.get(source)?.active > 0 &&
            !source.matches?.(".bp-paper-edit-form[phx-change]")) return;
        coordinator.markDirty(source);
        if (source.matches?.(".bp-paper-edit-form[phx-change]")) {
          const record = recordFor(source);
          record.formSnapshot = bpPaperFallbackFormSnapshot(
            source,
            identityFor(source),
          );
          const sourceConflict = conflict?.source === source;
          if (!sourceConflict) record.fallbackUnsafe = false;
          // Native submit validates before dispatching a submit event. Clear
          // stale errors as the author corrects inputs, not after debounce.
          bpPaperValidateAuthoringForm(source);
          renderSaveStatus();
          // Own the legacy form's debounce so the actual autosave reply clears
          // the exit guard. Let target/form listeners run, but do not also let
          // LiveView's window-level phx-change binding enqueue a duplicate.
          event.stopPropagation();
          if (conflict) {
            clearTimeout(record.timer);
            record.timer = null;
            record.fallbackDeferred = true;
            if (sourceConflict) conflict.latestSnapshot = record.formSnapshot;
          } else if (record.active > 0 || mutationActive || mutationQueue.length) {
            clearTimeout(record.timer);
            record.timer = null;
            record.fallbackDeferred = true;
          } else {
            coordinator._scheduleFallback(source);
          }
        }
      };
      coordinator._sendFallback = (source, driver = null) => {
        const record = recordFor(source);
        if (!record.dirty) return Promise.resolve(true);
        if (conflict) return Promise.resolve(false);
        if (record.fallbackUnsafe) {
          coordinator._pauseFallbackForReview(source, record);
          return Promise.resolve(false);
        }
        if (record.active > 0) return record.pending || Promise.resolve(false);
        driver ||= [...members].find((member) => typeof member.pushEventTo === "function");
        if (!driver || !source.isConnected) return Promise.resolve(false);
        if (record.formSnapshot && !bpPaperRestoreFallbackForm(
          record.formSnapshot,
          source,
          identityFor(source),
          main,
        )) {
          coordinator._pauseFallbackForReview(source, record);
          return Promise.resolve(false);
        }
        bpPaperValidateAuthoringForm(source);
        if (source.checkValidity?.() === false) {
          source.reportValidity?.();
          return Promise.resolve(false);
        }

        clearTimeout(record.timer);
        record.timer = null;
        const event = source.getAttribute("phx-change");
        const target = source.getAttribute("phx-target") || source;
        const params = Object.fromEntries(new FormData(source));
        const mutation = record.mutationEntry
          ? { promise: coordinator.retryMutation(record.mutationEntry), entry: record.mutationEntry }
          : bpPaperMutation(driver, source, event, params, {
            target,
            onResult: (saved, result) => {
              if (saved || result?.discarded) {
                record.mutationEntry = null;
                coordinator._renderDetachedReferenceDraft();
              }
            },
          });
        record.mutationEntry = mutation.entry || record.mutationEntry;
        renderSaveStatus();
        let snapshotSaved = false;
        const pending = mutation.promise
          .then((saved) => {
            snapshotSaved = saved;
            return saved;
          })
          .finally(() => {
            if (record.pending === pending) record.pending = null;
            coordinator._renderDetachedReferenceDraft();
            if (
              snapshotSaved && source.isConnected && record.dirty && record.active === 0
            ) {
              // A later document mutation may already be queued or in flight.
              // Keep this newer form snapshot in the deferred set so each ACK
              // can advance its reviewed revision before it is serialized.
              // Scheduling it now drops that marker and can send the snapshot
              // from behind a sibling form against the sibling's old base.
              if (mutationActive || mutationQueue.length) {
                record.fallbackDeferred = true;
              } else {
                coordinator._scheduleFallback(source);
              }
            }
          });
        record.pending = pending;
        return pending;
      };
      coordinator._scheduleFallback = (source) => {
        const record = recordFor(source);
        clearTimeout(record.timer);
        record.fallbackDeferred = false;
        const rawDelay = source.getAttribute("phx-debounce");
        const delay = /^\d+$/.test(rawDelay || "") ? Number(rawDelay) : 500;
        record.timer = setTimeout(() => {
          record.timer = null;
          coordinator._sendFallback(source);
        }, delay);
      };
      coordinator._onBeforeUnload = (event) => {
        if (discardReloadBypass) {
          discardReloadBypass = false;
          return;
        }
        if (!coordinator.hasUnsaved()) return;
        event.preventDefault();
        event.returnValue = "";
      };
      coordinator._onNavigate = () => {
        const currentPosition = bpPaperHistoryPosition(window.history.state);
        if (currentPosition != null) historyPosition = currentPosition;
      };
      coordinator._onNavigationApiNavigate = (event) => {
        if (event.navigationType !== "traverse") return;
        const destinationKey = event.destination?.key;
        if (navigationReplayKey && destinationKey === navigationReplayKey) {
          navigationReplayKey = null;
          return;
        }
        if (!coordinator.hasUnsaved() || !event.cancelable || !destinationKey ||
            typeof window.navigation?.traverseTo !== "function") return;
        event.preventDefault();
        event.stopImmediatePropagation?.();
        if (navigationSave) return;
        navigationSave = coordinator.drain().then((saved) => {
          navigationSave = null;
          if (!saved) return false;
          navigationReplayKey = destinationKey;
          let result;
          try {
            result = window.navigation.traverseTo(destinationKey);
          } catch (_) {
            navigationReplayKey = null;
            return false;
          }
          if (!result?.committed || !result?.finished) {
            navigationReplayKey = null;
            return false;
          }
          return Promise.all([result.committed, result.finished])
            .then(() => true)
            .catch(() => {
              navigationReplayKey = null;
              return false;
            });
        });
      };
      const finishHistoryNavigation = () => {
        if (historyPhase !== "saving" || historySaveResult == null) return;
        if (historySaveResult) {
          historyPhase = "replay";
          window.history.go(historyDelta);
        } else {
          historyPhase = null;
          historyDelta = null;
        }
        historySaveResult = null;
      };
      coordinator._onPopState = (event) => {
        const nextPosition = bpPaperHistoryPosition(event.state);
        if (historyPhase === "restoring") {
          event.stopImmediatePropagation();
          if (
            historyPosition != null && nextPosition != null &&
            nextPosition !== historyPosition
          ) {
            window.history.go(historyPosition - nextPosition);
            return;
          }
          historyPosition = nextPosition;
          historyPhase = "saving";
          historySaveResult = null;
          coordinator.drain().then((saved) => {
            historySaveResult = saved;
            finishHistoryNavigation();
          });
          return;
        }
        if (historyPhase === "blocking") {
          event.stopImmediatePropagation();
          if (
            historyPosition != null && nextPosition != null &&
            nextPosition !== historyPosition
          ) {
            window.history.go(historyPosition - nextPosition);
            return;
          }
          historyPosition = nextPosition;
          historyPhase = "saving";
          finishHistoryNavigation();
          return;
        }
        if (historyPhase === "replay") {
          historyPhase = null;
          historyDelta = null;
          historyPosition = nextPosition;
          return;
        }
        if (historyPhase === "saving") {
          event.stopImmediatePropagation();
          if (
            historyPosition != null && nextPosition != null &&
            nextPosition !== historyPosition
          ) {
            historyPhase = "blocking";
            window.history.go(historyPosition - nextPosition);
          }
          return;
        }
        if (!coordinator.hasUnsaved()) {
          historyPosition = nextPosition;
          return;
        }
        // Phoenix stamps monotonic positions in its history state. Restore the
        // exact current entry before doing asynchronous work; once every save
        // is acknowledged, replay the original Back/Forward delta exactly once.
        if (
          historyPosition != null && nextPosition != null &&
          nextPosition !== historyPosition
        ) {
          event.stopImmediatePropagation();
          historyDelta = nextPosition - historyPosition;
          historySaveResult = null;
          historyPhase = "restoring";
          window.history.go(-historyDelta);
        }
      };
      coordinator._onClick = (event) => {
        if (event.defaultPrevented || event.button !== 0 || event.metaKey ||
            event.ctrlKey || event.shiftKey || event.altKey) return;
        const historyControl = event.target.closest?.("[data-paper-history-action]");
        const historyDirection = historyControl?.dataset.paperHistoryAction;
        if (historyControl && ["undo", "redo"].includes(historyDirection) &&
            main.contains(historyControl)) {
          event.preventDefault();
          event.stopImmediatePropagation();
          coordinator._requestHistory(historyDirection, historyControl);
          return;
        }
        const target = event.target.closest?.("a[href], [phx-click]");
        if (!target || replayTargets.has(target)) {
          if (target) replayTargets.delete(target);
          return;
        }
        const clickEvent = target.getAttribute("phx-click");
        const structural = PAPER_STRUCTURAL_EVENTS.has(clickEvent) ||
          (clickEvent === "inner-array-op" &&
            !target.closest?.('[phx-hook="BarkparkFieldBridge"]'));
        const betaPanel = target.closest?.('[data-test-id="studio-doc-beta-editor"]');
        const modeSwitch = clickEvent === "editor-set-mode" &&
          betaPanel === main.closest?.('[data-test-id="studio-doc-beta-editor"]');
        const anchor = target.matches("a[href]");
        if (anchor) {
          const href = target.getAttribute("href");
          if (!href || href.startsWith("#") || target.hasAttribute("download") ||
              target.getAttribute("target") === "_blank") return;
        }
        if (!anchor && !structural && !modeSwitch) return;
        if ((anchor || modeSwitch) && !coordinator.hasUnsaved()) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        if (structural) {
          const driver = [...members].find((member) =>
            typeof member.pushEventTo === "function" || typeof member.pushEvent === "function",
          );
          if (!driver) return;
          const phxTarget = target.getAttribute("phx-target");
          coordinator.run(() => bpPaperMutation(
            driver,
            target,
            target.getAttribute("phx-click"),
            bpPaperEventParams(target),
            typeof driver.pushEventTo === "function"
              ? { target: phxTarget || target }
              : {},
          ).promise);
          return;
        }
        coordinator.run(() => {
          let replayTarget = target;
          if (modeSwitch) {
            const mode = target.getAttribute("phx-value-mode");
            replayTarget = [...betaPanel.querySelectorAll('[phx-click="editor-set-mode"]')]
              .find((candidate) => candidate.getAttribute("phx-value-mode") === mode);
          }
          if (!replayTarget?.isConnected) return;
          replayTargets.add(replayTarget);
          replayTarget.click();
        });
      };
      coordinator._onSubmit = (event) => {
        const form = event.target;
        if (!PAPER_STRUCTURAL_SUBMITS.has(form?.getAttribute?.("phx-submit")) ||
            replayTargets.has(form)) {
          if (replayTargets.has(form)) replayTargets.delete(form);
          return;
        }
        event.preventDefault();
        event.stopImmediatePropagation();
        bpPaperValidateAuthoringForm(form);
        if (form.checkValidity?.() === false) {
          form.reportValidity?.();
          return;
        }
        const driver = [...members].find((member) =>
          typeof member.pushEventTo === "function" || typeof member.pushEvent === "function",
        );
        if (!driver) return;
        const params = Object.fromEntries(new FormData(form, event.submitter || undefined));
        const restoreCollectionFocus = bpPaperCollectionFocus(form, event.submitter);
        const restoreOptionFocus = bpPaperOptionFocus(form, event.submitter);
        const rotateConsumedCollectionId = bpPaperRotateConsumedCollectionId(form, event.submitter);
        const options = typeof driver.pushEventTo === "function"
          ? { target: form.getAttribute("phx-target") || form }
          : {};
        options.onResult = (saved) => {
          if (!saved) return;
          // onResult belongs to the retained queue entry, so an exact retry
          // reaches this callback too. Defer until the receipt handler applies
          // its correlated LiveView echo; that repaint may restore a consumed
          // hidden ID or replace the operated collection row.
          Promise.resolve().then(() => {
            rotateConsumedCollectionId();
            restoreCollectionFocus();
            restoreOptionFocus();
          }).catch((error) => {
            try {
              console.error("Acknowledged collection form could not restore its local controls.", error);
            } catch (_) {}
          });
        };
        coordinator.run(() => bpPaperMutation(
          driver,
          form,
          form.getAttribute("phx-submit"),
          bpPaperEventParams(event.submitter, params),
          options,
        ).promise);
      };
      document.addEventListener("input", coordinator._onInput);
      document.addEventListener("change", coordinator._onInput);
      document.addEventListener("focusin", coordinator._onNativeFocus);
      document.addEventListener("focusout", coordinator._onNativeBlur);
      document.addEventListener("click", coordinator._onClick, true);
      document.addEventListener("submit", coordinator._onSubmit, true);
      window.addEventListener("beforeunload", coordinator._onBeforeUnload);
      window.addEventListener("popstate", coordinator._onPopState, true);
      window.addEventListener("phx:navigate", coordinator._onNavigate);
      window.navigation?.addEventListener?.("navigate", coordinator._onNavigationApiNavigate);
      paperExitCoordinators.set(main, coordinator);
      renderHistoryControls();
    }
    return coordinator.register(hook);
  }

  function bpReleasePaperExitCoordinator(hook) {
    hook._bpPaperExitCoordinator?.release(hook);
  }

  function bpPaperCanvasRecoveryBundle(editorRoot) {
    const documentKey = editorRoot?.dataset?.paperDocKey;
    if (!documentKey) return null;
    const paperMain = editorRoot.closest?.("main");
    let revision = editorRoot.dataset.paperRev ?? paperMain?.dataset?.paperRev;
    const fragments = [];

    editorRoot.querySelectorAll('[phx-hook="BarkparkPaperCanvas"]').forEach((wrapper) => {
      if (!wrapper.isConnected ||
          wrapper.closest(".bp-paper-editor[data-paper-doc-key]") !== editorRoot) return;
      const canvas = wrapper.querySelector("bp-paper-canvas");
      let draft;
      if (typeof canvas?.recoverySnapshot === "function") {
        try {
          draft = canvas.recoverySnapshot();
        } catch (_error) {
          draft = {
            mode: "unknown",
            serialization_error: "The live canvas draft could not be serialized.",
          };
        }
      } else {
        draft = {
          mode: "unknown",
          serialization_error: "The live canvas recovery serializer was unavailable.",
        };
      }
      const context = {};
      for (const [key, value] of [
        ["container_id", wrapper.dataset.paperContainerId],
        ["container_kind", wrapper.dataset.paperContainerKind],
        ["container_run", wrapper.dataset.paperContainerRun],
        ["container_row_id", wrapper.dataset.paperContainerRowId],
        ["container_column_index", wrapper.dataset.paperContainerColumnIndex],
      ]) {
        if (value != null && value !== "") context[key] = value;
      }
      if (wrapper.dataset.canvasBlocks != null) {
        try {
          const confirmedBlocks = JSON.parse(wrapper.dataset.canvasBlocks);
          const confirmedRunIds = Array.isArray(confirmedBlocks)
            ? confirmedBlocks.map((block) => block?.id)
            : [];
          if (confirmedRunIds.length > 0 && confirmedRunIds.every((id) =>
            typeof id === "string" && id.trim() !== ""
          ) && new Set(confirmedRunIds).size === confirmedRunIds.length) {
            context.container_run_ids = confirmedRunIds;
          }
        } catch (_error) {
          // The exact raw confirmed source remains in the fragment below.
        }
      }
      fragments.push({
        wrapper_id: wrapper.id || null,
        run_id: wrapper.id?.startsWith("paper-canvas-")
          ? wrapper.id.slice("paper-canvas-".length)
          : null,
        context,
        source: {
          ...(wrapper.dataset.canvasDataset != null
            ? { dataset: wrapper.dataset.canvasDataset }
            : {}),
          ...(wrapper.dataset.canvasBlocks != null
            ? { confirmed_blocks_json: wrapper.dataset.canvasBlocks }
            : {}),
          ...(wrapper.dataset.paperRev != null
            ? { paper_revision: wrapper.dataset.paperRev }
            : {}),
          ...(wrapper.dataset.documentRev != null
            ? { document_revision: wrapper.dataset.documentRev }
            : {}),
        },
        draft,
      });
    });

    return {
      format: "barkpark-paper-canvas-recovery",
      version: 1,
      scope: "canvas-fragments",
      notice: "Recovery bundle for preserved canvas fragments; not a complete Paper document export.",
      document: {
        key: documentKey,
        ...(revision != null
          ? { revision }
          : {}),
      },
      fragments,
    };
  }

  function bpPaperDownloadCanvasRecovery(event) {
    if (event.defaultPrevented || event.button !== 0) return;
    const button = event.target.closest?.("[data-paper-canvas-export-draft]");
    if (!button) return;
    const warning = button.closest?.('[data-test-id="paper-canvas-resume-warning"]');
    const targetId = button.dataset.paperEditorTarget;
    const editorRoot = targetId ? document.getElementById(targetId) : null;
    if (!warning || !editorRoot || warning.nextElementSibling !== editorRoot ||
        editorRoot.dataset.paperCanvasResumeHalt !== "true" ||
        !editorRoot.hasAttribute("inert")) return;
    const bundle = bpPaperCanvasRecoveryBundle(editorRoot);
    if (!bundle) return;

    event.preventDefault();
    const blob = new window.Blob([`${JSON.stringify(bundle, null, 2)}\n`], {
      type: "application/json",
    });
    const href = window.URL.createObjectURL(blob);
    const download = document.createElement("a");
    const safeKey = bundle.document.key.replace(/[^a-zA-Z0-9._-]+/g, "-").slice(0, 120) || "paper";
    download.href = href;
    download.download = `${safeKey}-canvas-recovery.json`;
    download.click();
    Promise.resolve().then(() => window.URL.revokeObjectURL(href));
  }

  document.addEventListener("click", bpPaperDownloadCanvasRecovery);

  function bpPaperReloadCanvasRecovery(event, reload) {
    if (event.defaultPrevented || event.button !== 0) return false;
    const button = event.target.closest?.('[data-test-id="paper-canvas-reload-server"]');
    if (!button) return false;
    const warning = button.closest?.('[data-test-id="paper-canvas-resume-warning"]');
    const editorRoot = warning?.nextElementSibling;
    if (!warning || !editorRoot ||
        !editorRoot.matches?.(".bp-paper-editor[data-paper-doc-key]") ||
        editorRoot.dataset.paperCanvasResumeHalt !== "true" ||
        !editorRoot.hasAttribute("inert")) return false;
    const coordinator = paperExitCoordinators.get(editorRoot.closest("main"));
    if (!coordinator) return false;
    event.preventDefault();
    return coordinator.discardLocalDraftAndReload(reload);
  }

  window.BarkparkPaperEditorReloadCanvasRecovery = bpPaperReloadCanvasRecovery;
  document.addEventListener("click", bpPaperReloadCanvasRecovery);

  function bpPaperBeforeElUpdated(fromEl, toEl) {
    const paperEditorRootsWithin = (element) => {
      if (!element?.querySelectorAll) return [];
      const roots = [...element.querySelectorAll(".bp-paper-editor[data-paper-doc-key]")];
      if (element.matches?.(".bp-paper-editor[data-paper-doc-key]")) roots.unshift(element);
      return roots;
    };
    const fromPaperRoots = paperEditorRootsWithin(fromEl);
    const toPaperRoots = paperEditorRootsWithin(toEl);
    toPaperRoots.forEach((toRoot) => {
      if (!toRoot.id) return;
      const fromRoot = fromPaperRoots.find((candidate) =>
        candidate.id === toRoot.id &&
        candidate.dataset.paperDocKey === toRoot.dataset.paperDocKey
      );
      if (!fromRoot) return;
      const recoveryCoordinator = paperExitCoordinators.get(fromRoot.closest("main"));
      recoveryCoordinator?.captureReferenceDraftReplacement?.(
        fromRoot,
        toRoot.id,
        toRoot.dataset.paperDocKey,
      );
      const wasRootHalted = fromRoot.dataset.paperCanvasResumeHalt === "true";
      const nextRootState = toRoot.dataset.paperCanvasResumeState;
      const willRootHalt = toRoot.dataset.paperCanvasResumeHalt === "true" &&
        (nextRootState === "pending" || nextRootState === "blocked");
      const liveCanvases = [...fromRoot.querySelectorAll("bp-paper-canvas")].filter(
        (canvas) => canvas.closest(".bp-paper-editor[data-paper-doc-key]") === fromRoot,
      );
      if (!wasRootHalted && willRootHalt) {
        liveCanvases.forEach((canvas) => canvas.captureResumeFocus?.());
      } else if (wasRootHalted && !willRootHalt) {
        Promise.resolve().then(() => {
          liveCanvases.forEach((canvas) => canvas.restoreResumeFocus?.());
        });
      }
    });

    const resumeState = toEl?.dataset?.paperCanvasResumeState;
    const samePaperEditor = fromEl?.id && fromEl.id === toEl?.id &&
      fromEl.dataset?.paperDocKey &&
      fromEl.dataset.paperDocKey === toEl?.dataset?.paperDocKey;
    const wasHalted = fromEl?.dataset?.paperCanvasResumeHalt === "true";
    const willHalt = toEl?.dataset?.paperCanvasResumeHalt === "true" &&
      (resumeState === "pending" || resumeState === "blocked");
    if (willHalt && samePaperEditor) {
      // LiveView snapshots phx-update="ignore" from the OLD element before
      // calling this callback, so the server's new ignore marker cannot cancel
      // this first reconnect morph. Give morphdom an exact clone of the live
      // children instead: keyed ignored editors reconcile to themselves and
      // retain their DOM-owned drafts, history, selection, and form state. The
      // server warning is a sibling outside this frozen root.
      if (resumeState === "blocked") {
        fromEl.querySelectorAll('[phx-hook="BarkparkPaperCanvas"]').forEach((wrapper) => {
          wrapper[PAPER_CANVAS_LEASE_OVERFLOW] = true;
        });
      }
      toEl.replaceChildren(...Array.from(fromEl.childNodes, (child) => child.cloneNode(true)));
      return;
    }
    if (!fromEl?.matches?.("[data-paper-terminal-boundary]") ||
        !toEl?.matches?.("[data-paper-terminal-boundary]") ||
        fromEl.id !== toEl.id) return;
    const guardActive = fromEl.dataset.paperTerminalGuarded === "true" ||
      (fromEl.dataset.paperTerminalSupported === "true" &&
       toEl.dataset.paperTerminalSupported !== "true");
    if (!guardActive) return;
    const main = fromEl.closest?.("main");
    const coordinator = main && paperExitCoordinators.get(main);
    if (!coordinator?.firstUnsavedWithin(fromEl)) return;
    toEl.replaceChildren(...Array.from(fromEl.childNodes, (child) => child.cloneNode(true)));
    toEl.dataset.paperTerminalGuarded = "true";
  }

  function bpPaperDiscardPendingSource(source) {
    const editor = source?.matches?.("bp-paper-canvas, bp-paper-editor")
      ? source
      : source?.querySelector?.("bp-paper-canvas, bp-paper-editor");
    if (typeof editor?.resolveConflictWithServerBlock === "function") {
      editor.resolveConflictWithServerBlock(editor.block);
      return true;
    }
    if (typeof editor?.resolveConflictWithServerBlocks === "function") {
      editor.resolveConflictWithServerBlocks(editor.blocks);
      return true;
    }
    return false;
  }

  function bpRunPaperAction(coordinator, action) {
    if (coordinator) return coordinator.run(action).catch(() => false);
    return Promise.resolve().then(action).then(() => true).catch(() => false);
  }

  // Finish local edits and wait for their save replies before unmounting the
  // editor. A refused save leaves the paper open with its server halt message.
  Hooks.BarkparkPaperEditToggle = {
    mounted() {
      this._main = this.el.closest("main");
      this._exitCoordinator = bpPaperExitCoordinator(this);
      this._onClick = async (event) => {
        if (this.el.dataset.editing !== "true") return;
        event.preventDefault();
        event.stopImmediatePropagation();
        if (this._saving) return;
        this._saving = true;
        this.el.disabled = true;
        this.el.setAttribute("aria-busy", "true");
        try {
          await bpRunPaperAction(
            this._exitCoordinator,
            () => this.pushEvent("paper-toggle-edit", {}),
          );
        } catch (_) {
          // A disconnected toggle is still editing; the finally block restores
          // the button so the user can explicitly retry.
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
      bpReleasePaperExitCoordinator(this);
    },
  };

  // Preserve a dirty nested Terminal editor when an authoritative update makes
  // the parent unsupported. The LiveSocket DOM callback keeps the old subtree;
  // this hook turns the matching revision into the ordinary conflict flow.
  Hooks.BarkparkTerminalBoundary = {
    mounted() {
      this._exitCoordinator = bpPaperExitCoordinator(this);
      this._observeGuardedRevision = (rev, requestId = null) => {
        if (this.el.dataset.paperTerminalGuarded !== "true" ||
            rev == null || this._guardedTerminalRevision === rev) return false;
        this._guardedTerminalRevision = rev;
        const source = this._exitCoordinator?.firstUnsavedWithin(this.el) || this.el;
        return this._exitCoordinator?.observeRevision({
          rev,
          requestId,
          observedDocumentKey: this.el.dataset.paperTerminalDocumentKey ||
            this.el.closest?.("[data-paper-doc-key]")?.dataset.paperDocKey,
          source,
          reloadOnLatest: true,
          apply: () => this._exitCoordinator?.requestReloadWhenClean(),
        });
      };
      this._onBlockUpdate = (payload) => {
        if (!payload || payload.block_id !== this.el.dataset.paperTerminalId ||
              this.el.dataset.paperTerminalGuarded !== "true") return;
        this._observeGuardedRevision(payload.rev, payload.request_id);
      };
      this.handleEvent("bp:block-update", this._onBlockUpdate);
    },
    updated() {
      this._observeGuardedRevision?.(bpPaperRevisionFrom(this.el));
    },
    destroyed() {
      bpReleasePaperExitCoordinator(this);
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
        this._exitCoordinator = bpPaperExitCoordinator(this);
        this._pendingSaves = new Set();
        this._mutationEntries = [];
        const pushOp = (op, editor) => {
          let mutation;
          mutation = bpPaperMutation(this, this.el, "paper-op", op, {
            onResult: (saved, result) => {
              let tableProjectionApplied = true;
              if (saved && op?.op?.startsWith?.("patch-table-")) {
                const hasProjection = Object.prototype.hasOwnProperty.call(
                  result || {},
                  "table_projection",
                );
                let applied = false;
                const observed = hasProjection && result?.table_projection_rev != null &&
                  this._exitCoordinator?.observeRevision({
                    rev: result.table_projection_rev,
                    requestId: result.request_id,
                    source: this.el,
                    apply: () => {
                      applied = editor?.applyTableProjection?.(result.table_projection, {
                        requestId: result.request_id,
                        rev: result.table_projection_rev,
                      }) === true;
                    },
                  });
                tableProjectionApplied = observed === true && applied;
                if (!tableProjectionApplied) {
                  this._exitCoordinator?.markDirty(this.el);
                  editor?.dispatchEvent?.(new CustomEvent("bp-error", {
                    detail: {
                      code: "table_projection_receipt_invalid",
                      error: "The saved Table result could not be verified. Your draft is retained.",
                    },
                    bubbles: true,
                    composed: true,
                  }));
                }
              }
              editor?.tableMutationResult?.(op, saved && tableProjectionApplied, result);
              if (saved || result?.discarded) this._mutationEntries = this._mutationEntries.filter(
                (entry) => entry !== mutation.entry,
              );
            },
          });
          editor?.trackTableMutation?.(op, mutation.requestId);
          if (mutation.entry) this._mutationEntries.push(mutation.entry);
          const pending = mutation.promise
            .finally(() => this._pendingSaves.delete(pending));
          this._pendingSaves.add(pending);
          return pending;
        };
        this._onOp = (e) => {
          if (!e.target?.matches?.(
            'bp-paper-editor[data-editor-mode="card-body"], bp-paper-editor[data-editor-mode="table"]',
          )) {
            this._exitCoordinator?.markDirty(this.el);
          }
          pushOp(e.detail, e.target);
        };
        this.el.addEventListener("bp-op", this._onOp);
        this._onLocalChange = (e) => {
          if (!e.target?.matches?.(
            'bp-paper-editor[data-editor-mode="card-body"], bp-paper-editor[data-editor-mode="table"]',
          ) ||
              !e.detail || typeof e.detail !== "object") return;
          e.detail.token = this._exitCoordinator?.markDirty(this.el) || null;
        };
        this.el.addEventListener("bp-local-change", this._onLocalChange);
        this._onNoop = (e) => {
          this._exitCoordinator?.settleNoop(this.el, e.detail?.token);
        };
        this.el.addEventListener("bp-noop", this._onNoop);
        this._onFlushPending = (event) => {
          const editor = this.el.querySelector("bp-paper-editor");
          editor?.flushPendingChanges?.();
          const tableSettlement = editor?.waitForTableSettlement?.();
          if (!this._pendingSaves.size && this._mutationEntries.length) {
            const retry = this._exitCoordinator?.retryMutation(this._mutationEntries[0]);
            if (retry) {
              const pending = retry.finally(() => this._pendingSaves.delete(pending));
              this._pendingSaves.add(pending);
            }
          }
          if (this._pendingSaves.size || tableSettlement) {
            event.detail.waitUntil((async () => {
              while (this._pendingSaves.size) {
                const results = await Promise.all([...this._pendingSaves]);
                if (!results.every(Boolean)) return false;
              }
              if (tableSettlement && await tableSettlement !== true) return false;
              while (this._pendingSaves.size) {
                const results = await Promise.all([...this._pendingSaves]);
                if (!results.every(Boolean)) return false;
              }
              return true;
            })());
          }
        };
        this.el.addEventListener("bp-flush-pending", this._onFlushPending);

        // Slash menu (P3.3): the WC emits a bubbling/composed `bp-slash-insert`
        // CustomEvent {detail:{type, afterId}} when the user picks a block type
        // from the "/" popup. Forward it verbatim to the server's
        // paper-slash-insert handler, which builds the block (default_block +
        // insert-after) through the SAME paper_op pipeline patch-block uses.
        this._onSlash = (e) => {
          bpRunPaperAction(this._exitCoordinator, () =>
            bpPaperMutation(this, this.el, "paper-slash-insert", e.detail).promise
          );
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
          const tableMode = wc.getAttribute("data-editor-mode") === "table";
          const hasTableProjection = Object.prototype.hasOwnProperty.call(
            payload,
            "table_projection",
          );
          const nextBlock = tableMode && hasTableProjection
            ? payload.table_projection
            : payload.block;
          const apply = (mode) => {
            if (tableMode && typeof wc.applyTableProjection === "function") {
              if (mode === "external-resync") {
                wc.resolveConflictWithServerBlock(nextBlock);
              } else {
                wc.applyTableProjection(nextBlock, {
                  requestId: payload.request_id,
                  rev: payload.rev,
                });
              }
              return;
            }
            if (mode === "external-resync" &&
                typeof wc.resolveConflictWithServerBlock === "function") {
              wc.resolveConflictWithServerBlock(nextBlock);
            } else {
              wc.block = nextBlock;
            }
          };
          this._exitCoordinator?.observeRevision({
            rev: payload.rev,
            requestId: payload.request_id,
            apply,
            observedDocumentKey: this.el.closest?.("[data-paper-doc-key]")?.dataset.paperDocKey,
            source: this.el,
          }) || (payload.rev == null && apply("legacy"));
        };
        this.handleEvent("bp:block-update", this._onBlockUpdate);
      },
      destroyed() {
        this.el.removeEventListener("bp-op", this._onOp);
        this.el.removeEventListener("bp-local-change", this._onLocalChange);
        this.el.removeEventListener("bp-noop", this._onNoop);
        this.el.removeEventListener("bp-flush-pending", this._onFlushPending);
        this.el.removeEventListener("bp-slash-insert", this._onSlash);
        bpReleasePaperExitCoordinator(this);
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
        this._exitCoordinator = bpPaperExitCoordinator(this);
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
        this._opsReconnectRetryRequested = false;
        this._saveBridgeDestroyed = false;
        const refreshLeasePending = () => {
          this.el[PAPER_CANVAS_LEASE_PENDING] = this._opsQueue.some(
            (entry) => entry.boundaryLeasePending,
          );
        };
        const captureContainerContext = () => {
          const containerId = this.el.dataset.paperContainerId;
          const containerKind = this.el.dataset.paperContainerKind;
          const containerRowId = this.el.dataset.paperContainerRowId;
          const containerColumnIndex = this.el.dataset.paperContainerColumnIndex;
          const hasLegacyRunMarker = this.el.dataset.paperContainerRun != null;
          const hasContainerId = containerId != null;
          const hasContainerKind = containerKind != null;
          const hasContainerRowId = containerRowId != null;
          const hasContainerColumnIndex = containerColumnIndex != null;
          if (!hasContainerId && !hasLegacyRunMarker &&
              !hasContainerKind && !hasContainerRowId && !hasContainerColumnIndex) {
            return { wire: {}, invalid: false };
          }
          const confirmedBlocks = this.el.querySelector("bp-paper-canvas")?.blocks;
          const runIds = Array.isArray(confirmedBlocks)
            ? confirmedBlocks.map((block) => block?.id)
            : [];
          const validIds = runIds.length > 0 && runIds.every((id) =>
            typeof id === "string" && id.trim() !== ""
          ) && new Set(runIds).size === runIds.length;
          // A top-level canvas is still only one run of the document. Fold
          // head moves and appends inside that run, not across sibling widgets.
          if (containerKind === "document" && !hasContainerId && !hasLegacyRunMarker &&
              !hasContainerRowId && !hasContainerColumnIndex && validIds) {
            return { wire: Object.freeze({
              container_kind: "document",
              container_run_ids: Object.freeze([...runIds]),
            }), invalid: false };
          }
          if (!containerId?.trim() || !validIds) {
            return { wire: {}, invalid: true };
          }
          const legacyContext = hasContainerId && hasLegacyRunMarker &&
            !hasContainerKind && !hasContainerRowId && !hasContainerColumnIndex;
          const rowContext = hasContainerId && hasLegacyRunMarker &&
            hasContainerKind && ["steps", "tabs"].includes(containerKind) &&
            hasContainerRowId && !hasContainerColumnIndex && containerRowId.trim() !== "";
          const figureContext = hasContainerId && hasLegacyRunMarker &&
            containerKind === "figure" && !hasContainerRowId &&
            !hasContainerColumnIndex && runIds.length === 1;
          const sectionContext = hasContainerId && hasLegacyRunMarker &&
            containerKind === "section" && !hasContainerRowId && !hasContainerColumnIndex;
          const terminalContext = hasContainerId && hasLegacyRunMarker &&
            containerKind === "terminal" && !hasContainerRowId && !hasContainerColumnIndex;
          const parsedColumnIndex = /^(0|[1-9][0-9]*)$/.test(containerColumnIndex ?? "")
            ? Number(containerColumnIndex)
            : null;
          const columnsContext = hasContainerId && hasLegacyRunMarker &&
            containerKind === "columns" && !hasContainerRowId && hasContainerColumnIndex &&
            Number.isSafeInteger(parsedColumnIndex) && parsedColumnIndex >= 0;
          if (!legacyContext && !rowContext && !figureContext &&
              !sectionContext && !terminalContext && !columnsContext) {
            return { wire: {}, invalid: true };
          }
          return {
            wire: Object.freeze({
              ...(rowContext || figureContext || sectionContext || terminalContext || columnsContext ? {
                container_kind: containerKind,
              } : {}),
              ...(rowContext ? {
                container_row_id: containerRowId,
              } : {}),
              ...(columnsContext ? {
                container_column_index: parsedColumnIndex,
              } : {}),
              container_id: containerId,
              container_run_ids: Object.freeze([...runIds]),
            }),
            invalid: false,
          };
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
          if (entry.invalidContainerContext) {
            reportUnretryableOps(
              entry,
              "paper_ops_container_context_invalid",
              "Save paused: this nested editor lost its document position. Your edits are still here; copy them before reloading.",
            );
            return;
          }
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
          let mutation;
          if (entry.mutationEntry) {
            mutation = {
              entry: entry.mutationEntry,
              promise: this._exitCoordinator.retryMutation(entry.mutationEntry),
            };
          } else {
            mutation = bpPaperMutation(this, this.el, "paper-ops", {
              ops: entry.ops,
              ...entry.containerContext,
            }, {
              requestId: entry.requestId,
              reviewRequired: entry.conflictBlocks != null,
              onResult: (saved, result) => {
                if (saved && result?.retained_lease_overflow === true) {
                  this.el[PAPER_CANVAS_LEASE_OVERFLOW] = true;
                } else if (saved && result &&
                    Object.prototype.hasOwnProperty.call(result, "retained_leases")) {
                  const replyLeaseSet = bpPaperCanvasLeaseSet(result.retained_leases);
                  if (replyLeaseSet.valid) {
                    this.el[PAPER_CANVAS_LEASES] = replyLeaseSet.leases;
                    entry.boundaryLeasePending = false;
                    this.el[PAPER_CANVAS_LEASE_OVERFLOW] = false;
                  } else {
                    this.el[PAPER_CANVAS_LEASE_OVERFLOW] = true;
                  }
                }
                if (saved && !result?.discarded && entry.boundaryLeasePending) {
                  // A saved boundary mutation without an authoritative lease
                  // result cannot be allowed to fall out of the queue and lose
                  // the only reconnect ownership signal. Fail closed until its
                  // matching echo supplies a valid lease set.
                  this.el[PAPER_CANVAS_LEASE_OVERFLOW] = true;
                }
                this._sendingOps = false;
                if (result?.discarded) {
                  this._opsQueue = [];
                  this._opsFailed = false;
                  this._opsReconnectRetryRequested = false;
                  refreshLeasePending();
                  if (entry.conflictBlocks) {
                    this.el.querySelector("bp-paper-canvas")
                      ?.resolveConflictWithServerBlocks?.(entry.conflictBlocks);
                  }
                  return;
                }
                if (saved && this._opsQueue[0] === entry) {
                  this._opsQueue.shift();
                }
                refreshLeasePending();
                const canvas = this.el.querySelector("bp-paper-canvas");
                if (saved && result?.request_id && entry.seq != null) {
                  if (canvas?.identifyOpsRequest?.(entry.seq, result.request_id, entry.requestId)) {
                    entry.requestId = result.request_id;
                  }
                }
                let acknowledgementError = null;
                if (entry.seq != null &&
                    typeof canvas?.acknowledgeOps === "function") {
                  try {
                    canvas.acknowledgeOps(entry.seq, saved);
                  } catch (error) {
                    acknowledgementError = error;
                  }
                }
                if (saved) {
                  entry.transportRetryable = false;
                  this._opsReconnectRetryRequested = false;
                  this._opsFailed = false;
                  sendNextOps();
                } else {
                  this._opsFailed = true;
                  entry.transportRetryable = result == null;
                  if (entry.transportRetryable && this._opsReconnectRetryRequested) {
                    this._retryQueuedOpsAfterReconnect?.();
                  } else if (!entry.transportRetryable) {
                    this._opsReconnectRetryRequested = false;
                  }
                }
                if (acknowledgementError) throw acknowledgementError;
              },
            });
            entry.mutationEntry = mutation.entry;
          }
          const pending = mutation.promise
            .then((saved) => {
              // retryMutation can refuse locally (expired/conflicted/no longer
              // queued) without invoking the adapter callback. Do not leave
              // the hook permanently marked in flight in that case.
              if (!saved && this._sendingOps && this._opsQueue[0] === entry) {
                this._sendingOps = false;
                this._opsFailed = true;
                this._opsReconnectRetryRequested = false;
              }
              return saved;
            })
            .finally(() => this._pendingSaves.delete(pending));
          this._pendingSaves.add(pending);
        };
        this._retryQueuedOpsAfterReconnect = () => {
          if (this._saveBridgeDestroyed) return false;
          const entry = this._opsQueue[0];
          if (!entry || entry.unretryable) return false;
          this._opsReconnectRetryRequested = true;
          if (this._sendingOps) return true;
          if (Date.now() >= entry.expiresAt) {
            this._opsReconnectRetryRequested = false;
            this._opsFailed = false;
            sendNextOps();
            return false;
          }
          if (!entry.transportRetryable) {
            this._opsReconnectRetryRequested = false;
            return false;
          }
          this._opsReconnectRetryRequested = false;
          entry.transportRetryable = false;
          this._opsFailed = false;
          sendNextOps();
          return true;
        };
        this._onCanvasOps = (e) => {
          this._exitCoordinator?.markDirty(this.el);
          const containerContext = captureContainerContext();
          const boundaryLeasePending = !containerContext.invalid &&
            ["document", "section", "columns"].includes(containerContext.wire.container_kind) &&
            bpPaperOpsInsertRetainedBoundary(e.detail.ops);
          const entry = {
            ops: e.detail.ops,
            seq: e.detail.seq,
            boundaryLeasePending,
            conflictBlocks: e.detail.conflictBlocks || null,
            containerContext: containerContext.wire,
            invalidContainerContext: containerContext.invalid,
            requestId: this._exitCoordinator?.requestId() || bpPaperRequestId(),
            expiresAt: Date.now() + PAPER_OP_RETRY_TTL_MS,
          };
          const canvas = this.el.querySelector("bp-paper-canvas");
          if (entry.seq != null && typeof canvas?.identifyOpsRequest === "function") {
            canvas.identifyOpsRequest(entry.seq, entry.requestId);
          }
          this._opsQueue.push(entry);
          refreshLeasePending();
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
            const apply = (mode) => {
              const active = this._opsQueue.find((entry) =>
                entry.mutationEntry?.requestId === payload.request_id);
              if (active?.seq != null && payload.request_id) {
                if (wc.identifyOpsRequest?.(active.seq, payload.request_id, active.requestId)) {
                  active.requestId = payload.request_id;
                }
              }
              if (mode === "external-resync" &&
                  typeof wc.resolveConflictWithServerBlocks === "function") {
                wc.resolveConflictWithServerBlocks(run.blocks);
              } else {
                wc.applyServerBlocks(run.blocks, {
                  mode,
                  requestId: payload.request_id,
                });
              }
              // A validated server echo authoritatively replaces reconnect
              // ownership leases (a successful mutation reply can install them
              // earlier). Keep the opaque tokens on this exact ignored
              // run wrapper so a later LiveSocket join can resume ownership
              // before its first render without persisting document or draft data.
              if (run.retained_lease_overflow === true) {
                this.el[PAPER_CANVAS_LEASE_OVERFLOW] = true;
              } else if (Object.prototype.hasOwnProperty.call(run, "retained_leases")) {
                const echoLeaseSet = bpPaperCanvasLeaseSet(run.retained_leases);
                if (echoLeaseSet.valid) {
                  this.el[PAPER_CANVAS_LEASES] = echoLeaseSet.leases;
                  if (active) active.boundaryLeasePending = false;
                  refreshLeasePending();
                  this.el[PAPER_CANVAS_LEASE_OVERFLOW] = false;
                } else {
                  this.el[PAPER_CANVAS_LEASE_OVERFLOW] = true;
                }
              }
            };
            this._exitCoordinator?.observeRevision({
              rev: payload.rev,
              requestId: payload.request_id,
              apply,
              observedDocumentKey: this.el.closest?.("[data-paper-doc-key]")?.dataset.paperDocKey,
              source: this.el,
            }) || (payload.rev == null && apply("legacy"));
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
        this._fleetSources = {};
        this._paintFleet = (id, html, sourceBlock) => {
          const hole = this.el.querySelector(
            `[data-bp-fleet-id="${(window.CSS && CSS.escape) ? CSS.escape(id) : id}"] [data-bp-fleet-body]`,
          );
          if (!hole) return; // this render's block is not in THIS run's WC
          // Native Stats fields own paint timing while focused. Other fleet
          // kinds retain the existing display-only injection unchanged.
          if (!hole.dispatchEvent(new CustomEvent("bp-fleet-paint", {
            detail: { html, sourceBlock }, cancelable: true,
          }))) return;
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
            this._fleetSources[r.block_id] = r.source_block;
            this._paintFleet(r.block_id, r.html, r.source_block);
          });
        };
        this.handleEvent("bp:block-html", this._onBlockHtml);

        // Re-inject any stashed fleet HTML whenever this hook's element is updated
        // (a WC remount rebuilds the loading-chip holes from data-canvas-blocks).
        this._repaintFleet = () => {
          Object.keys(this._fleetRenders).forEach((id) =>
            this._paintFleet(id, this._fleetRenders[id], this._fleetSources[id]),
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
        const editorRoot = this.el.closest(".bp-paper-editor[data-paper-doc-key]");
        this._exitCoordinator?.rebindMain?.(
          this.el.closest("main"),
          editorRoot?.dataset.paperDocKey,
        );
        if (typeof this._repaintFleet === "function") this._repaintFleet();
      },
      disconnected() {
        // Capture before LiveView's reconnect patch can make the Studio shell
        // inert or move its responsive column. The WC owns all cancellation
        // and identity guards; this hook only supplies the earlier lifecycle
        // edge that is not observable from the eventual halt morph.
        this.el.querySelector("bp-paper-canvas")?.captureResumeFocus?.();
      },
      reconnected() {
        const editorRoot = this.el.closest(".bp-paper-editor[data-paper-doc-key]");
        this._exitCoordinator?.rebindMain?.(
          this.el.closest("main"),
          editorRoot?.dataset.paperDocKey,
        );
        this._retryQueuedOpsAfterReconnect?.();
        const canvas = this.el.querySelector("bp-paper-canvas");
        if (editorRoot && !editorRoot.hasAttribute("inert") &&
            editorRoot.dataset.paperCanvasResumeHalt !== "true") {
          Promise.resolve().then(() => canvas?.restoreResumeFocus?.());
        }
      },
      destroyed() {
        this._saveBridgeDestroyed = true;
        this._opsReconnectRetryRequested = false;
        this._retryQueuedOpsAfterReconnect = null;
        this._opsQueue = [];
        delete this.el[PAPER_CANVAS_LEASES];
        delete this.el[PAPER_CANVAS_LEASE_PENDING];
        delete this.el[PAPER_CANVAS_LEASE_OVERFLOW];
        this.el.removeEventListener("bp-canvas-ops", this._onCanvasOps);
        this.el.removeEventListener("bp-flush-pending", this._onFlushPending);
        this.el.removeEventListener("bp-ready", this._onCanvasReady);
        bpReleasePaperExitCoordinator(this);
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
        this._exitCoordinator = bpPaperExitCoordinator(this);
        const blockId = this.el.dataset.blockId;
        const fieldType = this.el.dataset.fieldType;

        this._pendingSaves = new Set();
        this._mutationEntries = [];
        const pushOp = (op) => {
          let mutation;
          mutation = bpPaperMutation(this, this.el, "paper-op", op, {
            onResult: (saved, result) => {
              if (saved || result?.discarded) this._mutationEntries = this._mutationEntries.filter(
                (entry) => entry !== mutation.entry,
              );
            },
          });
          if (mutation.entry) this._mutationEntries.push(mutation.entry);
          const pending = mutation.promise
            .finally(() => this._pendingSaves.delete(pending));
          this._pendingSaves.add(pending);
          return pending;
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
          if (!this._pendingSaves.size && this._mutationEntries.length) {
            const retry = this._exitCoordinator?.retryMutation(this._mutationEntries[0]);
            if (retry) {
              const pending = retry.finally(() => this._pendingSaves.delete(pending));
              this._pendingSaves.add(pending);
            }
          }
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
            this._exitCoordinator?.markDirty(this.el);
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
            this._exitCoordinator?.markDirty(this.el);
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
          this._exitCoordinator?.markDirty(this.el);
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
        bpReleasePaperExitCoordinator(this);
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

    // BarkparkFigureImageBridge keeps an editable Figure looking like the
    // reader. The server renders the canonical image child; this hook only
    // turns that rendered image into the contextual picker trigger and sends a
    // source-only patch for the child. The following LiveView render remains
    // authoritative for the visible image and every other child field.
    Hooks.BarkparkFigureImageBridge = {
      mounted() {
        this._exitCoordinator = bpPaperExitCoordinator(this);
        this._pendingSaves = new Set();
        this._mutationEntries = [];
        this._pendingImageSources = new Set();

        const picker = this.el.querySelector("bp-media-picker[data-paper-figure-image-picker]");
        this._picker = picker;
        const triggerSelector = "[data-paper-figure-image-trigger]";
        const inactive = () => !picker || !!this.el.closest("[inert]");
        const openPicker = () => {
          if (inactive()) return false;
          let opened = false;
          try { opened = picker.openBrowser?.() === true; } catch (_err) { opened = false; }
          if (!opened) picker.openFileDialog?.();
          return true;
        };
        const mediaUrl = (event) => {
          const metaUrl = event.target?.meta?.url;
          if (typeof metaUrl === "string" && metaUrl) return { valid: true, src: metaUrl };
          const value = event.detail?.value;
          if (typeof value !== "string") return { valid: false };
          if (!value.trim().startsWith("{")) return { valid: true, src: value };
          try {
            const parsed = JSON.parse(value);
            return typeof parsed?.url === "string"
              ? { valid: true, src: parsed.url }
              : { valid: false };
          } catch (_err) {
            return { valid: false };
          }
        };
        const pushSource = (src) => {
          this._pendingImageSources.add(src);
          let mutation;
          mutation = bpPaperMutation(this, this.el, "paper-op", {
            op: "patch-block",
            id: this.el.dataset.blockId,
            patch: { src },
          }, {
            onResult: (saved, result) => {
              if (saved || result?.discarded) {
                this._pendingImageSources.delete(src);
                this._mutationEntries = this._mutationEntries.filter(
                  (entry) => entry !== mutation.entry,
                );
              }
            },
          });
          if (mutation.entry) this._mutationEntries.push(mutation.entry);
          const pending = mutation.promise.finally(() => this._pendingSaves.delete(pending));
          this._pendingSaves.add(pending);
          return pending;
        };

        this._onClick = (event) => {
          const trigger = event.target?.closest?.(triggerSelector);
          if (!trigger || !this.el.contains(trigger)) return;
          event.preventDefault();
          if (inactive()) return;
          trigger.focus?.();
          openPicker();
        };
        this._onKeydown = (event) => {
          if (event.key !== "Enter" && event.key !== " ") return;
          const trigger = event.target?.closest?.(triggerSelector);
          if (!trigger || !this.el.contains(trigger)) return;
          event.preventDefault();
          if (inactive()) return;
          openPicker();
        };
        this._onChange = (event) => {
          if (event.target !== picker || inactive()) return;
          const parsed = mediaUrl(event);
          if (!parsed.valid) return;
          const { src } = parsed;
          if (src === (this.el.dataset.imageSrc || "") || this._pendingImageSources.has(src)) return;
          this._exitCoordinator?.markDirty(this.el);
          pushSource(src);
        };
        this._onFlushPending = (event) => {
          if (!this._pendingSaves.size && this._mutationEntries.length) {
            const retry = this._exitCoordinator?.retryMutation(this._mutationEntries[0]);
            if (retry) {
              const pending = retry.finally(() => this._pendingSaves.delete(pending));
              this._pendingSaves.add(pending);
            }
          }
          if (this._pendingSaves.size) {
            event.detail.waitUntil(
              Promise.all([...this._pendingSaves]).then((results) => results.every(Boolean)),
            );
          }
        };

        this.el.addEventListener("click", this._onClick);
        this.el.addEventListener("keydown", this._onKeydown);
        this.el.addEventListener("bp-change", this._onChange);
        this.el.addEventListener("bp-flush-pending", this._onFlushPending);
      },
      updated() {
        this._exitCoordinator?.refreshHistoryControls?.();
        // The picker shell is intentionally ignored so LiveView never replaces
        // an open native picker. Refresh its public value from the authoritative
        // server-rendered source when the surrounding Figure hook updates.
        if (this._picker && this._picker.value !== this.el.dataset.imageSrc) {
          this._picker.value = this.el.dataset.imageSrc || "";
        }
      },
      destroyed() {
        bpReleasePaperExitCoordinator(this);
        this.el.removeEventListener("click", this._onClick);
        this.el.removeEventListener("keydown", this._onKeydown);
        this.el.removeEventListener("bp-change", this._onChange);
        this.el.removeEventListener("bp-flush-pending", this._onFlushPending);
      },
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
        this._exitCoordinator = bpPaperExitCoordinator(this);
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
          bpRunPaperAction(this._exitCoordinator, () =>
            bpPaperMutation(this, this.el, "paper-move-block-to", {
              id: draggedId, "after-id": afterId,
            }).promise
          );
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
      updated() {
        // LiveView can replace the footer controls while preserving this hook.
        // Re-apply coordinator-owned controls and recovery UI after the server
        // morph removes client-only presentation nodes.
        this._exitCoordinator?.refreshPresentation?.();
      },
      destroyed() {
        this.el.removeEventListener("dragstart", this._onDragStart);
        this.el.removeEventListener("dragover", this._onDragOver);
        this.el.removeEventListener("drop", this._onDrop);
        this.el.removeEventListener("dragend", this._onDragEnd);
        bpReleasePaperExitCoordinator(this);
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
        exitCoordinator: hook._exitCoordinator,
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
      const activate = () => {
        if (action === "move-up")
          return bpPaperMutation(ctx, ctx.el, "paper-move-block", {
            id: ctx.blockId, dir: "up",
          }).promise;
        if (action === "move-down")
          return bpPaperMutation(ctx, ctx.el, "paper-move-block", {
            id: ctx.blockId, dir: "down",
          }).promise;
        if (action === "delete")
          return bpPaperMutation(ctx, ctx.el, "paper-delete-block", {
            id: ctx.blockId,
          }).promise;
      };
      bpRunPaperAction(ctx.exitCoordinator, activate);
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
        this._exitCoordinator = bpPaperExitCoordinator(this);
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
        bpReleasePaperExitCoordinator(this);
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
        this._exitCoordinator = bpPaperExitCoordinator(this);
        this._dirty = false;
        this._formVersion = 0;
        this._pendingSaves = new Set();
        this._fieldMutationEntries = [];
        this._paperForm = this.el.matches("form[data-paper-field-flush]")
          ? this.el
          : this.el.closest("form[data-paper-field-flush]");
        this._ownsPaperForm = this._paperForm === this.el;
        this._pendingRequests = new Map();

        const trackFormChange = () => {
          this._formVersion += 1;
          this._dirty = true;
          this._exitCoordinator?.markDirty(this.el);
        };
        if (this._ownsPaperForm) {
          this._onFormInput = trackFormChange;
          this._onFormChange = trackFormChange;
          this.el.addEventListener("input", this._onFormInput);
          this.el.addEventListener("change", this._onFormChange);
          this._onPaperFieldSaveResult = (payload) => {
            const request = payload && this._pendingRequests.get(payload.request_id);
            if (request) request.finish(payload);
          };
          this._paperSaveResultRef = this.handleEvent(
            "bp:paper-field-save-result",
            this._onPaperFieldSaveResult,
          );
          this._onArrayOpClick = (event) => {
            const button = event.target.closest?.('[phx-click="inner-array-op"]');
            if (!button || !this.el.contains(button) || button.disabled) return;

            // Own this structural event in both reader edit mode and Studio so
            // its parent write participates in the same correlated barrier.
            event.preventDefault();
            event.stopImmediatePropagation();
            const params = { action: button.getAttribute("phx-value-action") };
            const index = button.getAttribute("phx-value-index");
            if (index != null) params.index = index;
            bpRunPaperAction(this._exitCoordinator, () => {
              this._formVersion += 1;
              const version = this._formVersion;
              this._dirty = false;
              return this._pushCorrelated("inner-array-op", params, version);
            });
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
          const requestId = this._exitCoordinator?.requestId() || bpPaperRequestId();
          if (!requestId) return this._trackSave(Promise.resolve(false), version);
          const target = this.el.getAttribute("phx-target") || this.el;
          const send = (wire) => new Promise((resolve) => {
            let finished = false;
            const wireRequestId = wire.request_id;
            const finish = (reply) => {
              if (finished) return;
              finished = true;
              clearTimeout(timeout);
              this._pendingRequests.delete(wireRequestId);
              resolve(reply || null);
            };
            const timeout = setTimeout(() => finish(null), 10000);
            this._pendingRequests.set(wireRequestId, { finish });
            Promise.resolve(this.pushEventTo(target, event, wire))
              .then((results) => {
                if (!Array.isArray(results) || results.length === 0 ||
                    results.some((result) => result.status !== "fulfilled")) finish(null);
              })
              .catch(() => finish(null));
          });
          const mutation = this._exitCoordinator.mutate(this.el, {
            requestId,
            payload: params,
            send,
            onResult: (saved, result) => {
              if (saved || result?.discarded) this._fieldMutationEntries = this._fieldMutationEntries.filter(
                (entry) => entry !== mutation.entry,
              );
              if ((saved || result?.discarded) && this._formVersion === version) this._dirty = false;
            },
          });
          if (mutation.entry) this._fieldMutationEntries.push(mutation.entry);
          return this._trackSave(mutation.promise, version);
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
            const mutation = bpPaperMutation(this, this.el, event, params, { target });
            save = mutation.promise;
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
          if (!this._pendingSaves.size && this._fieldMutationEntries.length) {
            this._trackSave(
              this._exitCoordinator.retryMutation(this._fieldMutationEntries[0]),
              this._formVersion,
            );
          } else if (this._dirty) {
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
        bpReleasePaperExitCoordinator(this);
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
  // Re-evaluated by LiveSocket on every join, not captured at initial load.
  // This is only a document-bound presentation hint. The server rechecks write
  // authority; no draft text, credentials, or mutation payload rides the hint.
  window.BarkparkPaperEditorConnectParams = () => {
    const toggle = document.querySelector('#paper-edit-toggle[data-editing="true"]');
    if (!toggle && document.querySelector("#paper-edit-toggle")) return {};
    const toggleMain = toggle?.closest("main");
    const documentRoot = toggle
      ? (toggleMain?.matches(".bp-paper-editor[data-paper-doc-key]")
          ? toggleMain
          : toggleMain?.querySelector(".bp-paper-editor[data-paper-doc-key]"))
      : [...document.querySelectorAll(".bp-paper-editor[data-paper-doc-key]")].find((candidate) =>
          candidate.querySelector('[phx-hook="BarkparkPaperCanvas"]'));
    const key = documentRoot?.dataset.paperDocKey;
    if (!key) return {};

    const leases = [];
    const seen = new Set();
    let totalLength = 0;
    let leasePending = false;
    let leaseOverflow = false;
    documentRoot.querySelectorAll('[phx-hook="BarkparkPaperCanvas"]').forEach((wrapper) => {
      if (!wrapper.isConnected ||
          wrapper.closest(".bp-paper-editor[data-paper-doc-key]") !== documentRoot) return;
      if (wrapper[PAPER_CANVAS_LEASE_PENDING] === true) leasePending = true;
      if (wrapper[PAPER_CANVAS_LEASE_OVERFLOW] === true) leaseOverflow = true;
      const wrapperLeaseSet = bpPaperCanvasLeaseSet(wrapper[PAPER_CANVAS_LEASES] || []);
      if (!wrapperLeaseSet.valid) {
        leaseOverflow = true;
        return;
      }
      for (const lease of wrapperLeaseSet.leases) {
        if (seen.has(lease)) continue;
        if (leases.length >= PAPER_CANVAS_LEASE_MAX_COUNT ||
            totalLength + lease.length > PAPER_CANVAS_LEASE_MAX_TOTAL_LENGTH) {
          leaseOverflow = true;
          return;
        }
        leases.push(lease);
        seen.add(lease);
        totalLength += lease.length;
      }
    });

    return {
      ...(toggle ? { paper_editing_key: key } : {}),
      ...(leases.length || leasePending || leaseOverflow ? { paper_canvas_lease_key: key } : {}),
      ...(!leaseOverflow && leases.length ? { paper_canvas_leases: leases } : {}),
      ...(leasePending ? { paper_canvas_lease_pending: true } : {}),
      ...(leaseOverflow ? { paper_canvas_lease_overflow: true } : {}),
    };
  };
  window.BarkparkPaperEditorBeforeElUpdated = bpPaperBeforeElUpdated;
  window.BarkparkPaperEditorHooks = Hooks;
})();
