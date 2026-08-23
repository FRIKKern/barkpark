export const pageSchema = {
  name: 'page',
  type: 'document',
  title: 'Marketing Page',
  visibility: 'public',
  fields: [
    { name: 'title', type: 'string', required: true },
    { name: 'slug', type: 'slug', source: 'title' },
    { name: 'heroImage', type: 'image' },
    { name: 'subtitle', type: 'text', rows: 2 },
    // The page body: the canonical, type-keyed PortableDocument block array
    // (Barkpark's own block grammar). `surface: 'body'` marks it as the trailing
    // body region; the frontend renders it with `@barkpark/react`'s PortableDoc,
    // NOT Sanity PortableText.
    { name: 'body', type: 'richText', surface: 'body' },
  ],
} as const
