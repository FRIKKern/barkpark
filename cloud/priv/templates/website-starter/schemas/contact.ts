/**
 * The document type `app/contact/actions.ts` creates on every form submission.
 *
 * `visibility: 'private'` — these are inbound messages from anonymous visitors
 * and carry an email address, so they must NOT be readable through the public
 * anonymous read path the rest of this site uses. Create this schema in Studio
 * before pointing the contact form at a real project.
 */
export const contactSchema = {
  name: 'contact',
  type: 'document',
  title: 'Contact Submission',
  visibility: 'private',
  fields: [
    { name: 'name', type: 'string', required: true },
    { name: 'email', type: 'string', required: true },
    { name: 'message', type: 'text', rows: 6, required: true },
    { name: 'receivedAt', type: 'datetime' },
  ],
} as const
