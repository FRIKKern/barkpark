import type { ErrorEnvelope } from './types.js'

/**
 * Thrown when a Barkpark v1 request returns a non-2xx response with a
 * structured error envelope. See docs/api-v1.md § Error codes.
 */
export class BarkparkError extends Error {
  readonly code: ErrorEnvelope['code']
  readonly status: number
  readonly details: Record<string, string[]> | undefined

  constructor(status: number, envelope: ErrorEnvelope) {
    super(`[${envelope.code}] ${envelope.message}`)
    this.name = 'BarkparkError'
    this.code = envelope.code
    this.status = status
    this.details = envelope.details
  }

  /**
   * Parse a fetch Response into a BarkparkError, or return null if the body
   * is not a structured error envelope.
   */
  static async fromResponse(response: Response): Promise<BarkparkError> {
    let envelope: ErrorEnvelope
    try {
      const body = (await response.json()) as { error?: ErrorEnvelope }
      if (body && body.error && typeof body.error === 'object' && 'code' in body.error) {
        envelope = body.error
      } else {
        envelope = {
          code: 'internal_error',
          message: `Unexpected response shape (HTTP ${response.status})`,
        }
      }
    } catch {
      envelope = {
        code: 'internal_error',
        message: `Non-JSON response (HTTP ${response.status})`,
      }
    }
    return new BarkparkError(response.status, envelope)
  }
}
