"use client";

import { useEffect, useRef } from "react";
import type { ReactNode } from "react";
import Script from "next/script";
import type { Block } from "@/lib/papers";

/* ── web-component contract (mirrors api/assets/paper-editor/src/index.js) ──
 * The bundle self-registers <bp-paper-editor> via customElements.define and
 * reads its block from the `el.block` property (preferred by _readBlock) or a
 * `data-block` JSON attribute. Read mode is opted into with the reflected
 * `editable="false"` attribute (observedAttributes → threaded into the TipTap
 * Editor as editable:false; bubble/slash/emit all gated off). The element
 * self-cleans in disconnectedCallback — teardown is just DOM removal, with no
 * controller to destroy (unlike GraphView). The WC self-injects its own
 * stylesheet (/assets/bp-paper-editor.css) via ensureStyles(). */
interface BpPaperEditorElement extends HTMLElement {
  block?: Block;
}

export interface PaperEditorMountProps {
  /** Top-level PROSE blocks (paragraph | heading | list) — one <bp-paper-editor>
   * is mounted per entry, in order. */
  proseBlocks: Block[];
  /** Pre-rendered, server-computed read-mode markup for the NON-prose blocks,
   * already interleaved in document order with `null` holes where a prose
   * editor goes. The client never imports the renderer — it only fills holes. */
  slots: Array<ReactNode | null>;
  /** Extra classes on the host article wrapper. */
  className?: string;
}

/**
 * Client boundary for the read-mode paper embed. Clones the graph-view.tsx
 * mount/teardown shape verbatim, adapted for a self-registering custom element
 * instead of a window factory:
 *   • readiness check is customElements.get("bp-paper-editor") (not a window fn);
 *   • we create N elements and set el.block (no controller, no destroy());
 *   • teardown removes the elements — the WC self-cleans on disconnect.
 *
 * The script-load race is handled both ways exactly like GraphView: try init
 * immediately (bundle may already be present), else poll on a 60ms interval
 * gated by scriptReadyRef until the element is defined, then construct once.
 *
 * Read-only: editable="false" suppresses TipTap edits, so no bp-op edit events
 * fire and none are wired.
 */
export function PaperEditorMount({
  proseBlocks,
  slots,
  className,
}: PaperEditorMountProps) {
  const hostRefs = useRef<Array<HTMLDivElement | null>>([]);
  /** The <bp-paper-editor> elements we created, ref-tracked the way GraphView
   * tracks its controller — so teardown can remove exactly what we mounted. */
  const elRef = useRef<BpPaperEditorElement[]>([]);
  /** Flipped true once the script reports ready — lets the init poll
   * short-circuit the moment the custom element is guaranteed defined. */
  const scriptReadyRef = useRef(false);

  // INIT — once the custom element is defined AND the hosts are mounted, create
  // one <bp-paper-editor> per prose block. Polls to cover the
  // "script loads after mount" race, identical to graph-view.tsx.
  useEffect(() => {
    let cancelled = false;
    let pollId: ReturnType<typeof setInterval> | null = null;

    const init = () => {
      if (cancelled || elRef.current.length) return false;
      if (!customElements.get("bp-paper-editor")) return false;
      proseBlocks.forEach((block, i) => {
        const host = hostRefs.current[i];
        if (!host) return;
        const el = document.createElement(
          "bp-paper-editor",
        ) as BpPaperEditorElement;
        // The reflected `editable` attr is read in connectedCallback →
        // editable:false (read mode). Must be the bare attribute, not
        // data-editable, which the WC does not observe.
        el.setAttribute("editable", "false");
        // _readBlock() prefers el.block over the attribute; set before append so
        // the editor mounts with this block's content at connectedCallback time.
        el.block = block;
        host.appendChild(el);
        elRef.current.push(el);
      });
      return elRef.current.length > 0;
    };

    if (!init()) {
      pollId = setInterval(() => {
        if (scriptReadyRef.current || customElements.get("bp-paper-editor")) {
          if (init() && pollId) {
            clearInterval(pollId);
            pollId = null;
          }
        }
      }, 60);
    }

    return () => {
      cancelled = true;
      if (pollId) clearInterval(pollId);
      // The WC self-cleans in disconnectedCallback; teardown is DOM removal.
      for (const el of elRef.current) el.remove();
      elRef.current = [];
    };
    // Construct ONCE per mount — the block set is stable for a given paper.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Walk the interleaved slot array: a non-null slot is a server-rendered
  // non-prose node (rendered verbatim); a null slot is a prose hole — we emit a
  // host <div> the INIT effect fills with a <bp-paper-editor>. The two streams
  // (slots / proseBlocks) advance in lockstep with document order.
  let proseIdx = 0;
  return (
    <>
      <Script
        src="/bp-paper-editor.bundle.js"
        strategy="afterInteractive"
        onReady={() => {
          scriptReadyRef.current = true;
        }}
        onLoad={() => {
          scriptReadyRef.current = true;
        }}
      />
      <div className={`flex flex-col gap-4 ${className ?? ""}`}>
        {slots.map((node, i) => {
          if (node !== null) return <div key={`s${i}`}>{node}</div>;
          const idx = proseIdx++;
          return (
            <div
              key={`p${i}`}
              ref={(node) => {
                hostRefs.current[idx] = node;
              }}
            />
          );
        })}
      </div>
    </>
  );
}
