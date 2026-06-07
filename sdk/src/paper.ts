/**
 * Paper builder — collects blocks and serialises the publish body the ingest
 * accepts: `{ slug, title?, style?, blocks: [...] }`.
 *
 * The ingest controller (BulldocsIngestController.ingest/2) matches on
 * `%{"slug" => slug, "blocks" => blocks}` and defaults `style` to "article".
 * `title` rides along in the attrs map; we only emit keys that were set.
 */

import type { Block } from "./blocks.js";

export interface PaperOptions {
  title?: string;
  /** Render palette. The ingest defaults this to "article" server-side. */
  style?: "article" | "email";
}

export interface PublishBody {
  slug: string;
  blocks: Block[];
  title?: string;
  style?: string;
}

export class Paper {
  readonly slug: string;
  readonly title: string | undefined;
  readonly style: string | undefined;
  private readonly blocks: Block[] = [];

  constructor(slug: string, opts: PaperOptions = {}) {
    this.slug = slug;
    this.title = opts.title;
    this.style = opts.style;
  }

  /** Append one or more blocks, in order. Chainable. */
  add(...blocks: Block[]): this {
    this.blocks.push(...blocks);
    return this;
  }

  /** Current block list (a copy — mutating it won't affect the builder). */
  getBlocks(): Block[] {
    return [...this.blocks];
  }

  /** The exact JSON publish body the ingest endpoint accepts. */
  toJSON(): PublishBody {
    const body: PublishBody = { slug: this.slug, blocks: [...this.blocks] };
    if (this.title !== undefined) body.title = this.title;
    if (this.style !== undefined) body.style = this.style;
    return body;
  }
}

/** Construct a Paper builder. */
export function paper(slug: string, opts: PaperOptions = {}): Paper {
  return new Paper(slug, opts);
}
