// AUTO-GENERATED — do not edit by hand.
// source: /v1/schemas/production
// schemaHash: e68b92f5591302bab63f73da77e1ff8d471e3ff4ed439ef69fd8920096bd957c
// mode: strict
// schemas: author, category, colors, navigation, page, post, project, siteSettings

// ---- Filter-op matrix (from ADR-006 / P1-b) --------------------------------
export type FieldKind = 'string' | 'number' | 'date' | 'boolean' | 'slug' | 'reference';
export type OpsForKind = {
  string: 'eq' | 'in' | 'ne';
  number: 'eq' | 'ne' | 'gt' | 'lt' | 'gte' | 'lte' | 'in';
  date: 'gt' | 'lt' | 'gte' | 'lte';
  boolean: 'eq';
  slug: 'eq' | 'in';
  reference: 'eq';
};

// Shape of per-document filter descriptor: each field → { kind, value }
type FilterField<K extends FieldKind, V> = { kind: K; value: V };

// Narrow: given a filter descriptor and an op, what is the accepted value?
type AcceptedValue<F, O extends string> =
  F extends FilterField<infer _K, infer V>
    ? O extends 'in' ? readonly V[] : V
    : never;

export interface Author {
  _id: string;
  _type: "author";
  _draft: boolean;
  _publishedId: string;
  _createdAt: string;
  _updatedAt: string;
  name: string;
  slug: { _type: 'slug'; current: string };
  bio: string;
  avatar: { _type: 'image'; asset: { _ref: string } } | null;
  email: string;
  role: "editor" | "writer" | "contributor" | "admin";
}

export type AuthorField = "_id" | "_type" | "_createdAt" | "_updatedAt" | "name" | "slug" | "bio" | "avatar" | "email" | "role";
export type AuthorFilter = {
  _id: FilterField<'string', string>;
  _type: FilterField<'string', "author">;
  _createdAt: FilterField<'date', string>;
  _updatedAt: FilterField<'date', string>;
  name: FilterField<'string', string>;
  slug: FilterField<'slug', string>;
  bio: FilterField<'string', string>;
  email: FilterField<'string', string>;
  role: FilterField<'string', "editor" | "writer" | "contributor" | "admin">;
};

export interface Category {
  _id: string;
  _type: "category";
  _draft: boolean;
  _publishedId: string;
  _createdAt: string;
  _updatedAt: string;
  title: string;
  slug: { _type: 'slug'; current: string };
  description: string;
  color: string;
}

export type CategoryField = "_id" | "_type" | "_createdAt" | "_updatedAt" | "title" | "slug" | "description" | "color";
export type CategoryFilter = {
  _id: FilterField<'string', string>;
  _type: FilterField<'string', "category">;
  _createdAt: FilterField<'date', string>;
  _updatedAt: FilterField<'date', string>;
  title: FilterField<'string', string>;
  slug: FilterField<'slug', string>;
  description: FilterField<'string', string>;
  color: FilterField<'string', string>;
};

export interface Colors {
  _id: string;
  _type: "colors";
  _draft: boolean;
  _publishedId: string;
  _createdAt: string;
  _updatedAt: string;
  primary: string;
  secondary: string;
  accent: string;
}

export type ColorsField = "_id" | "_type" | "_createdAt" | "_updatedAt" | "primary" | "secondary" | "accent";
export type ColorsFilter = {
  _id: FilterField<'string', string>;
  _type: FilterField<'string', "colors">;
  _createdAt: FilterField<'date', string>;
  _updatedAt: FilterField<'date', string>;
  primary: FilterField<'string', string>;
  secondary: FilterField<'string', string>;
  accent: FilterField<'string', string>;
};

export interface Navigation {
  _id: string;
  _type: "navigation";
  _draft: boolean;
  _publishedId: string;
  _createdAt: string;
  _updatedAt: string;
  title: string;
}

export type NavigationField = "_id" | "_type" | "_createdAt" | "_updatedAt" | "title";
export type NavigationFilter = {
  _id: FilterField<'string', string>;
  _type: FilterField<'string', "navigation">;
  _createdAt: FilterField<'date', string>;
  _updatedAt: FilterField<'date', string>;
  title: FilterField<'string', string>;
};

export interface Page {
  _id: string;
  _type: "page";
  _draft: boolean;
  _publishedId: string;
  _createdAt: string;
  _updatedAt: string;
  title: string;
  slug: { _type: 'slug'; current: string };
  body: unknown[];
  seoTitle: string;
  seoDescription: string;
  heroImage: { _type: 'image'; asset: { _ref: string } } | null;
}

export type PageField = "_id" | "_type" | "_createdAt" | "_updatedAt" | "title" | "slug" | "body" | "seoTitle" | "seoDescription" | "heroImage";
export type PageFilter = {
  _id: FilterField<'string', string>;
  _type: FilterField<'string', "page">;
  _createdAt: FilterField<'date', string>;
  _updatedAt: FilterField<'date', string>;
  title: FilterField<'string', string>;
  slug: FilterField<'slug', string>;
  seoTitle: FilterField<'string', string>;
  seoDescription: FilterField<'string', string>;
};

export interface Post {
  _id: string;
  _type: "post";
  _draft: boolean;
  _publishedId: string;
  _createdAt: string;
  _updatedAt: string;
  title: string;
  slug: { _type: 'slug'; current: string };
  status: "draft" | "published" | "archived";
  publishedAt: string;
  excerpt: string;
  body: unknown[];
  featuredImage: { _type: 'image'; asset: { _ref: string } } | null;
  author: { _type: 'reference'; _ref: string };
  featured: boolean;
}

export type PostField = "_id" | "_type" | "_createdAt" | "_updatedAt" | "title" | "slug" | "status" | "publishedAt" | "excerpt" | "body" | "featuredImage" | "author" | "featured";
export type PostFilter = {
  _id: FilterField<'string', string>;
  _type: FilterField<'string', "post">;
  _createdAt: FilterField<'date', string>;
  _updatedAt: FilterField<'date', string>;
  title: FilterField<'string', string>;
  slug: FilterField<'slug', string>;
  status: FilterField<'string', "draft" | "published" | "archived">;
  publishedAt: FilterField<'date', string>;
  excerpt: FilterField<'string', string>;
  author: FilterField<'reference', string>;
  featured: FilterField<'boolean', boolean>;
};

export interface Project {
  _id: string;
  _type: "project";
  _draft: boolean;
  _publishedId: string;
  _createdAt: string;
  _updatedAt: string;
  title: string;
  slug: { _type: 'slug'; current: string };
  client: string;
  status: "planning" | "active" | "completed" | "archived";
  description: unknown[];
  coverImage: { _type: 'image'; asset: { _ref: string } } | null;
  startDate: string;
  featured: boolean;
}

export type ProjectField = "_id" | "_type" | "_createdAt" | "_updatedAt" | "title" | "slug" | "client" | "status" | "description" | "coverImage" | "startDate" | "featured";
export type ProjectFilter = {
  _id: FilterField<'string', string>;
  _type: FilterField<'string', "project">;
  _createdAt: FilterField<'date', string>;
  _updatedAt: FilterField<'date', string>;
  title: FilterField<'string', string>;
  slug: FilterField<'slug', string>;
  client: FilterField<'string', string>;
  status: FilterField<'string', "planning" | "active" | "completed" | "archived">;
  startDate: FilterField<'date', string>;
  featured: FilterField<'boolean', boolean>;
};

export interface SiteSettings {
  _id: string;
  _type: "siteSettings";
  _draft: boolean;
  _publishedId: string;
  _createdAt: string;
  _updatedAt: string;
  title: string;
  description: string;
  logo: { _type: 'image'; asset: { _ref: string } } | null;
  analyticsId: string;
}

export type SiteSettingsField = "_id" | "_type" | "_createdAt" | "_updatedAt" | "title" | "description" | "logo" | "analyticsId";
export type SiteSettingsFilter = {
  _id: FilterField<'string', string>;
  _type: FilterField<'string', "siteSettings">;
  _createdAt: FilterField<'date', string>;
  _updatedAt: FilterField<'date', string>;
  title: FilterField<'string', string>;
  description: FilterField<'string', string>;
  analyticsId: FilterField<'string', string>;
};


export type DocumentMap = {
  "author": Author;
  "category": Category;
  "colors": Colors;
  "navigation": Navigation;
  "page": Page;
  "post": Post;
  "project": Project;
  "siteSettings": SiteSettings;
};
export type DocumentType = keyof DocumentMap;

export type FilterMap = {
  "author": AuthorFilter;
  "category": CategoryFilter;
  "colors": ColorsFilter;
  "navigation": NavigationFilter;
  "page": PageFilter;
  "post": PostFilter;
  "project": ProjectFilter;
  "siteSettings": SiteSettingsFilter;
};


// ---- Typed client -----------------------------------------------------------

export interface BaseClient {
  fetch(type: string, params: { filters: Array<[string, string, unknown]>; orders: Array<[string, 'asc' | 'desc']>; limit?: number; offset?: number }): Promise<unknown>;
}

export interface TypedBuilder<T extends DocumentType> {
  where<
    F extends keyof FilterMap[T],
    K extends FilterMap[T][F] extends FilterField<infer K0, infer _V> ? K0 : never,
    O extends OpsForKind[K & FieldKind],
  >(
    field: F,
    op: O,
    value: AcceptedValue<FilterMap[T][F], O & string>,
  ): TypedBuilder<T>;

  order<F extends keyof FilterMap[T]>(field: F, direction?: 'asc' | 'desc'): TypedBuilder<T>;
  limit(n: number): TypedBuilder<T>;
  offset(n: number): TypedBuilder<T>;
  find(): Promise<DocumentMap[T][]>;
  findOne(): Promise<DocumentMap[T] | null>;
}

export interface TypedClient {
  docs<T extends DocumentType>(type: T): TypedBuilder<T>;
  doc<T extends DocumentType>(type: T, id: string): Promise<DocumentMap[T] | null>;
}

export function typedClient(client: BaseClient): TypedClient {
  function makeBuilder<T extends DocumentType>(type: T): TypedBuilder<T> {
    const filters: Array<[string, string, unknown]> = [];
    const orders: Array<[string, 'asc' | 'desc']> = [];
    let _limit: number | undefined;
    let _offset: number | undefined;
    const builder: TypedBuilder<T> = {
      where(field, op, value) {
        filters.push([field as string, op as string, value as unknown]);
        return builder;
      },
      order(field, direction = 'asc') {
        orders.push([field as string, direction]);
        return builder;
      },
      limit(n) { _limit = n; return builder; },
      offset(n) { _offset = n; return builder; },
      async find() {
        const res = await client.fetch(type as string, { filters, orders, limit: _limit, offset: _offset });
        return res as DocumentMap[T][];
      },
      async findOne() {
        const res = await client.fetch(type as string, { filters, orders, limit: 1, offset: _offset });
        const arr = res as DocumentMap[T][];
        return arr[0] ?? null;
      },
    };
    return builder;
  }
  return {
    docs(type) { return makeBuilder(type); },
    async doc(type, _id) {
      return null;
    },
  };
}
