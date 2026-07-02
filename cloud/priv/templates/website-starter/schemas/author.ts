export const authorSchema = {
  name: 'author',
  type: 'document',
  title: 'Author',
  visibility: 'public',
  fields: [
    { name: 'name', type: 'string', required: true },
    { name: 'slug', type: 'slug', source: 'name' },
    { name: 'bio', type: 'text', rows: 4 },
    { name: 'avatar', type: 'image' },
  ],
} as const
