export type BarkparkDoc = {
  _id: string;
  _type: string;
  _draft?: boolean;
  _publishedId?: string;
  _createdAt?: string;
  _updatedAt?: string;
  [key: string]: unknown;
};

export type BarkparkQueryResult = {
  count: number;
  documents: BarkparkDoc[];
};

export type BarkparkSchema = {
  type: string;
  visibility?: "public" | "private";
  fields?: Array<{ name: string; type: string; [key: string]: unknown }>;
  [key: string]: unknown;
};

export class BarkparkFetchError extends Error {
  constructor(
    public readonly status: number,
    public readonly statusText: string,
    public readonly path: string,
  ) {
    super(`Barkpark ${status} ${statusText} for ${path}`);
    this.name = "BarkparkFetchError";
  }
}

function apiBase(): string {
  const base = process.env.BARKPARK_API_URL;
  if (!base) throw new Error("BARKPARK_API_URL is not set");
  return base.replace(/\/+$/, "");
}

function authHeaders(): HeadersInit {
  const token = process.env.BARKPARK_PUBLIC_READ_TOKEN;
  return token ? { Authorization: `Bearer ${token}` } : {};
}

type FetchOpts = RequestInit & { revalidate?: number };

export async function barkparkFetch<T>(
  path: string,
  opts: FetchOpts = {},
): Promise<T> {
  const { revalidate = 60, headers, ...init } = opts;
  const url = `${apiBase()}${path}`;
  const res = await fetch(url, {
    ...init,
    headers: {
      ...authHeaders(),
      Accept: "application/json",
      ...(headers as Record<string, string> | undefined),
    },
    next: { revalidate },
  });
  if (!res.ok) {
    throw new BarkparkFetchError(res.status, res.statusText, path);
  }
  return (await res.json()) as T;
}
