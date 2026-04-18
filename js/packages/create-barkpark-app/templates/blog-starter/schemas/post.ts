export const postSchema = {
  name: 'post',
  type: 'document',
  title: 'Post',
  visibility: 'public',
  fields: [
    { name: 'title', type: 'string', required: true },
    { name: 'slug', type: 'slug', source: 'title' },
    { name: 'excerpt', type: 'text', rows: 3 },
    { name: 'content', type: 'richText' },
    { name: 'author', type: 'reference', refType: 'author' },
    { name: 'coverImage', type: 'image' },
    { name: 'publishedAt', type: 'datetime' },
    { name: 'tags', type: 'array', of: { type: 'reference', refType: 'tag' } },
  ],
} as const
