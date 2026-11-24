// The Fable weekly limit (statusline-design.md §4.20). Claude Code reads it from
// the `anthropic-ratelimit-unified-7d_oi-*` headers of each model response
// (its `seven_day_overage_included` window), but hands it neither to the
// statusline payload nor to `$.session.usage()`. The mod copies it into the
// statusline state dir, one file per session, where statusline-command.sh
// reads the file of the session it renders.

const UTIL = 'anthropic-ratelimit-unified-7d_oi-utilization'
const RESET = 'anthropic-ratelimit-unified-7d_oi-reset'

export type FableLimit = { percent: number; resetsAt: number }

// The window from one response's headers (names lower-cased), or null when
// either header is absent or not a finite number. Utilization is a 0–1
// fraction; reset is epoch seconds.
export function parseFable(headers: Readonly<Record<string, string>> | undefined): FableLimit | null {
  if (!headers) return null
  const u = Number(headers[UTIL])
  const r = Number(headers[RESET])
  if (headers[UTIL] === undefined || headers[RESET] === undefined) return null
  if (!Number.isFinite(u) || !Number.isFinite(r) || u < 0 || r <= 0) return null
  return { percent: Math.min(100, Math.round(u * 100)), resetsAt: Math.round(r) }
}

// The session's file in the state dir: one per session, so a figure never
// outlives the account it was read on (an account switch starts sessions that
// write their own). Null for an id that is not a plain transcript name.
export function fableFile(dir: string, sessionId: string): string | null {
  return /^[A-Za-z0-9-]{1,64}$/.test(sessionId) ? `${dir}/fable-${sessionId}` : null
}

// The line statusline-command.sh reads with `read -r pct reset`.
export function fableLine(f: FableLimit): string {
  return `${f.percent} ${f.resetsAt}\n`
}

// The state dir as cc_state_dir_init resolves it (lib/format-utils.sh):
// $CC_STATUSLINE_STATE_DIR, else $XDG_RUNTIME_DIR/cc-statusline, else
// $HOME/.cache/cc-statusline. Null when none can be formed.
export function stateDir(env: Readonly<Record<string, string>>): string | null {
  if (env.CC_STATUSLINE_STATE_DIR) return env.CC_STATUSLINE_STATE_DIR
  if (env.XDG_RUNTIME_DIR) return `${env.XDG_RUNTIME_DIR}/cc-statusline`
  if (env.HOME) return `${env.HOME}/.cache/cc-statusline`
  return null
}
