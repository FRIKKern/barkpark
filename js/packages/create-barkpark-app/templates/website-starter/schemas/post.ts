export const postSchema = {
  name: 'post',
  type: 'document',
  title: 'Post',
  visibility: 'public',
  fields: [
    { name: 'title', type: 'string', required: true },
    { name: 'slug', type: 'slug', source: 'title' },
    { name: 'excerpt', type: 'text', rows: 3 },
    // The post body: the canonical, type-keyed PortableDocument block array
    // (Barkpark's own block grammar). `surface: 'body'` marks it as the trailing
    // body region; the frontend renders it with `@barkpark/react`'s PortableDoc,
    // NOT Sanity PortableText.
    { name: 'content', type: 'richText', surface: 'body' },
    { name: 'author', type: 'reference', refType: 'author' },
    { name: 'coverImage', type: 'image' },
    { name: 'publishedAt', type: 'datetime' },
    { name: 'tags', type: 'arrayOf', of: { type: 'string' } },
  ],
} as const
