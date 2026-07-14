// MSW server for Node. PATTERN copied from js/packages/core/tests/fixtures/server.ts.
import { setupServer } from "msw/node";
import { defaultHandlers } from "./handlers.js";

export const server = setupServer(...defaultHandlers);
