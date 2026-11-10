/**
 * A change the DakPush server refused (like a wrong auth hash or a bad tag),
 * a value the SDK refused before sending (code `invalid`), or the SDK not
 * running (code `not_started`).
 *
 * Network problems never fail: the change is saved and sent later.
 */
export class DakError extends Error {
  /** Like `invalid`, `identity_failed`, `not_started`. */
  readonly code: string;
  /** The refused field, when the server named one (like `external_id`). */
  readonly field: string | null;
  /** The server's HTTP status, when the server refused. */
  readonly status: number | null;

  constructor(
    message: string,
    code: string,
    field: string | null = null,
    status: number | null = null
  ) {
    super(message);
    this.name = 'DakError';
    this.code = code;
    this.field = field;
    this.status = status;
  }
}

/** Codes the native side uses for its own rejections. */
const NATIVE_CODES = new Set(['invalid', 'not_started', 'unavailable']);

/**
 * Turns what the native module rejects with (or sends as an error event)
 * into a DakError. Native rejections carry the DakPush code, field and status
 * in `userInfo`.
 */
export function toDakError(e: unknown): DakError {
  if (e instanceof DakError) return e;
  const any = (e ?? {}) as {
    message?: unknown;
    code?: unknown;
    field?: unknown;
    status?: unknown;
    userInfo?: unknown;
  };
  const info = (any.userInfo ?? {}) as Record<string, unknown>;
  const message =
    typeof any.message === 'string' && any.message.length > 0
      ? any.message
      : String(e);
  const code =
    str(info.code) ??
    (typeof any.code === 'string' && NATIVE_CODES.has(any.code)
      ? any.code
      : null) ??
    str(any.code) ??
    'unknown';
  const field = str(info.field) ?? str(any.field);
  const status = num(info.status) ?? num(any.status);
  return new DakError(message, code, field, status);
}

function str(v: unknown): string | null {
  return typeof v === 'string' && v.length > 0 ? v : null;
}

function num(v: unknown): number | null {
  if (typeof v === 'number' && Number.isFinite(v) && v > 0) return v;
  if (typeof v === 'string' && /^\d+$/.test(v)) return Number(v);
  return null;
}
