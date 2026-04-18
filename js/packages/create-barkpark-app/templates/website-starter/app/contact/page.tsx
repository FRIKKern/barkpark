'use client'

import { useActionState } from 'react'
import { submitContact, type ContactFormState } from './actions'

const initial: ContactFormState = { ok: false, message: '' }

export default function ContactPage() {
  const [state, formAction, pending] = useActionState(submitContact, initial)

  return (
    <div className="mx-auto max-w-lg space-y-6">
      <header className="space-y-2">
        <h1 className="text-4xl font-bold">Contact</h1>
        <p className="text-slate-600 dark:text-slate-300">
          Get in touch. Submissions create <code>contact</code> documents via the Barkpark mutate API.
        </p>
      </header>

      <form action={formAction} className="space-y-4">
        <label className="block">
          <span className="mb-1 block text-sm font-medium">Name</span>
          <input
            name="name"
            required
            className="w-full rounded border border-slate-300 bg-white px-3 py-2 dark:border-slate-700 dark:bg-slate-900"
          />
        </label>
        <label className="block">
          <span className="mb-1 block text-sm font-medium">Email</span>
          <input
            name="email"
            type="email"
            required
            className="w-full rounded border border-slate-300 bg-white px-3 py-2 dark:border-slate-700 dark:bg-slate-900"
          />
        </label>
        <label className="block">
          <span className="mb-1 block text-sm font-medium">Message</span>
          <textarea
            name="message"
            required
            rows={5}
            className="w-full rounded border border-slate-300 bg-white px-3 py-2 dark:border-slate-700 dark:bg-slate-900"
          />
        </label>
        <button
          type="submit"
          disabled={pending}
          className="rounded bg-brand px-4 py-2 font-medium text-white hover:bg-brand-dark disabled:opacity-50"
        >
          {pending ? 'Sending\u2026' : 'Send'}
        </button>
        {state.message ? (
          <p
            className={
              state.ok
                ? 'text-sm text-emerald-700 dark:text-emerald-400'
                : 'text-sm text-red-700 dark:text-red-400'
            }
          >
            {state.message}
          </p>
        ) : null}
      </form>
    </div>
  )
}
