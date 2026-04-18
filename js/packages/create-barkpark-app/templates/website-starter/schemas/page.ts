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
    { name: 'body', type: 'richText' },
  ],
} as const
