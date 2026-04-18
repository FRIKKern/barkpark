// MSW server setup for Node. Browser tests use setupWorker in a separate file (Wave 5).
import { setupServer } from 'msw/node'
import { defaultHandlers } from './handlers'

export const server = setupServer(...defaultHandlers)
