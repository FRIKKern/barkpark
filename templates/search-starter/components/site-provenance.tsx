import {
  buildIdentityLine,
  corpusProvenanceLine,
  type BuildIdentity,
  type CorpusProvenance,
} from "@/lib/provenance";

/**
 * The provenance surface: what this page is actually serving, said out loud.
 *
 * The build already stamps `bp-build-id` / `bp-content-rev` / `bp-doc-id` as
 * `<meta>` for the deploy HEALTH gate, so the MACHINE has had provenance all
 * along and the human has had none. This is the human half — the same values,
 * in a sentence, on the page.
 *
 * It renders NOTHING of its own: both lines come from `lib/provenance`, which
 * is pure and unit-pinned, and every value handed to it was READ by the page
 * (deploy markers from the boot env, counts and truncation flags from the
 * corpus payload). There is deliberately no constant in this file to go stale.
 *
 * VISUALLY QUIET on purpose: it inherits the landing caption's own type scale
 * (`text-[0.7rem]`) and the neutral `muted-text` token, and introduces no accent
 * colour, border, icon or badge — a status line, not a banner. The one machine
 * affordance is `data-bp-provenance="<state>"` on the wrapper, so a curl or a
 * DOM probe can assert WHICH state rendered without matching prose.
 */
export interface SiteProvenanceProps {
  /** Deploy markers, sentinels resolved to null (`lib/markers.buildIdentity`). */
  build: BuildIdentity;
  /** The corpus read, as the page received it (`lib/graph.CorpusGraph`). */
  corpus: CorpusProvenance;
}

export function SiteProvenance({ build, corpus }: SiteProvenanceProps) {
  const line = corpusProvenanceLine(corpus);
  return (
    <div className="mt-1.5" data-bp-provenance={line.state}>
      <p className="text-[0.7rem] leading-relaxed text-muted-text">{line.text}</p>
      <p className="mt-0.5 text-[0.7rem] leading-relaxed text-muted-text">
        {buildIdentityLine(build)}
      </p>
    </div>
  );
}
