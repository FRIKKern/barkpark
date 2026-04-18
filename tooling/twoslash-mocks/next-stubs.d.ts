/**
 * Ambient declarations for Next.js internals referenced by Barkpark docs
 * snippets rendered with shiki-twoslash.
 *
 * These mirror the public surface of Next.js 15.x — signatures only — so
 * the docs build can type-check ```ts twoslash fences without installing
 * the full next runtime. See tooling/twoslash-mocks/README.md.
 */

declare module "server-only" {
  const _marker: unique symbol;
  export default _marker;
}

declare module "client-only" {
  const _marker: unique symbol;
  export default _marker;
}

declare module "next/cache" {
  export function revalidateTag(tag: string): void;
  export function revalidatePath(path: string, type?: "layout" | "page"): void;
  export function unstable_noStore(): void;

  export interface UnstableCacheOptions {
    tags?: string[];
    revalidate?: number | false;
  }

  export function unstable_cache<A extends readonly unknown[], R>(
    cb: (...args: A) => Promise<R>,
    keyParts?: readonly string[],
    options?: UnstableCacheOptions
  ): (...args: A) => Promise<R>;
}

declare module "next/headers" {
  export interface ReadonlyHeaders {
    get(name: string): string | null;
    has(name: string): boolean;
    entries(): IterableIterator<[string, string]>;
    keys(): IterableIterator<string>;
    values(): IterableIterator<string>;
    forEach(
      callback: (value: string, key: string, parent: ReadonlyHeaders) => void
    ): void;
    [Symbol.iterator](): IterableIterator<[string, string]>;
  }

  export interface RequestCookie {
    name: string;
    value: string;
  }

  export interface ReadonlyRequestCookies {
    get(name: string): RequestCookie | undefined;
    getAll(name?: string): RequestCookie[];
    has(name: string): boolean;
    size: number;
    [Symbol.iterator](): IterableIterator<[string, RequestCookie]>;
  }

  export interface DraftMode {
    isEnabled: boolean;
    enable(): void;
    disable(): void;
  }

  export function headers(): Promise<ReadonlyHeaders>;
  export function cookies(): Promise<ReadonlyRequestCookies>;
  export function draftMode(): Promise<DraftMode>;
}

declare module "next/navigation" {
  export function notFound(): never;
  export function redirect(url: string, type?: "replace" | "push"): never;
  export function permanentRedirect(
    url: string,
    type?: "replace" | "push"
  ): never;

  export interface AppRouterInstance {
    push(href: string, options?: { scroll?: boolean }): void;
    replace(href: string, options?: { scroll?: boolean }): void;
    back(): void;
    forward(): void;
    refresh(): void;
    prefetch(href: string, options?: { kind?: "auto" | "full" }): void;
  }

  export function useRouter(): AppRouterInstance;
  export function usePathname(): string;

  export interface ReadonlyURLSearchParams {
    get(name: string): string | null;
    getAll(name: string): string[];
    has(name: string): boolean;
    toString(): string;
    entries(): IterableIterator<[string, string]>;
    keys(): IterableIterator<string>;
    values(): IterableIterator<string>;
    [Symbol.iterator](): IterableIterator<[string, string]>;
  }

  export function useSearchParams(): ReadonlyURLSearchParams;
  export function useParams<T = Record<string, string | string[]>>(): T;
}

declare module "next/og" {
  export interface ImageResponseOptions {
    width?: number;
    height?: number;
    emoji?:
      | "twemoji"
      | "blobmoji"
      | "noto"
      | "openmoji"
      | "fluent"
      | "fluentFlat";
    fonts?: Array<{
      name: string;
      data: ArrayBuffer;
      weight?: 100 | 200 | 300 | 400 | 500 | 600 | 700 | 800 | 900;
      style?: "normal" | "italic";
    }>;
    debug?: boolean;
    status?: number;
    statusText?: string;
    headers?: Record<string, string>;
  }

  export class ImageResponse extends Response {
    constructor(element: unknown, options?: ImageResponseOptions);
  }
}

declare module "next" {
  export interface Metadata {
    title?: string | { default: string; template?: string };
    description?: string;
    keywords?: string | string[];
    openGraph?: Record<string, unknown>;
    twitter?: Record<string, unknown>;
    [key: string]: unknown;
  }

  export interface NextPage<P = Record<string, unknown>> {
    (props: P): unknown;
  }
}

declare module "next/link" {
  interface LinkProps {
    href: string;
    children?: unknown;
    prefetch?: boolean;
    replace?: boolean;
    scroll?: boolean;
    [key: string]: unknown;
  }
  const Link: (props: LinkProps) => unknown;
  export default Link;
}

declare module "next/image" {
  interface ImageProps {
    src: string;
    alt: string;
    width?: number;
    height?: number;
    fill?: boolean;
    priority?: boolean;
    [key: string]: unknown;
  }
  const Image: (props: ImageProps) => unknown;
  export default Image;
}
