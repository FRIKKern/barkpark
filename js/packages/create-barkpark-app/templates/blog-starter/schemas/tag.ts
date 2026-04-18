export const tagSchema = {
  name: 'tag',
  type: 'document',
  title: 'Tag',
  visibility: 'public',
  fields: [
    { name: 'title', type: 'string', required: true },
    { name: 'slug', type: 'slug', source: 'title' },
    { name: 'description', type: 'text', rows: 3 },
  ],
} as const
