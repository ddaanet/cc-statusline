// The agent panel's subagent rows (statusline-design.md §4.19), drawn as the
// `body` of a `ui.render` hook on `AgentRow`. A port of the former
// lib/subagent-display.sh: the same elements, glyphs, colours and width
// fitting. Pure: the hook passes the agent, the row's columns and the time.
//
// Intensity is never touched: the row is dim or bold as the engine selects
// it, so segments close with the foreground reset only, never SGR 0, 1, 2 or
// 22. Widths count code points, as the shell's vislen counts UTF-8 lead bytes:
// every glyph used here is one cell.

const ESC = '\x1b['
export const RED = ESC + '31m'
export const GREEN = ESC + '32m'
export const YELLOW = ESC + '33m'
export const BLUE = ESC + '34m'
export const MAGENTA = ESC + '35m'
export const CYAN = ESC + '36m'
export const BRMAGENTA = ESC + '95m'
export const RESET_FG = ESC + '39m'

// U+F1C0 nf-fa-database, the context icon line 1 uses.
export const ICON_CTX = '\u{f1c0}'

// Control characters (C0, DEL, C1) and bidirectional overrides become spaces,
// so a model-written name cannot carry an escape sequence, a line break or a
// reordering into the row.
export function clean(s: unknown): string {
  return typeof s === 'string'
    ? s.replace(/[\x00-\x1f\x7f-\x9f\u{200e}\u{200f}\u{202a}-\u{202e}\u{2066}-\u{2069}]/gu, ' ')
    : ''
}

// A model id → the display name the rank keys on: claude-opus-5-5 → "Opus 5.5",
// claude-sonnet-4-5-20250929 → "Sonnet 4.5", claude-3-5-sonnet-20241022 →
// "Sonnet 3.5". A [1m]-style suffix, a prefix up to "claude-" and a trailing
// date are dropped; any other shape is kept as given (an unranked model).
export function modelName(id: string): string {
  let s = id.split('[')[0] ?? ''
  const at = s.lastIndexOf('claude-')
  if (at < 0) return id
  s = s.slice(at + 'claude-'.length).replace(/-[0-9]{8}$/, '')
  let fam = '', maj = '', min = ''
  let m = /^(opus|sonnet|haiku|fable)-([0-9]+)(?:-([0-9]+))?$/.exec(s)
  if (m) [fam, maj, min] = [m[1] ?? '', m[2] ?? '', m[3] ?? '']
  else if ((m = /^([0-9]+)(?:-([0-9]+))?-(opus|sonnet|haiku|fable)$/.exec(s))) [maj, min, fam] = [m[1] ?? '', m[2] ?? '', m[3] ?? '']
  else return id
  return fam.charAt(0).toUpperCase() + fam.slice(1) + ' ' + maj + (min ? '.' + min : '')
}

// 42 → "42s", 252 → "4m12", 3600 → "1h", as format_turn_dur.
export function formatDur(s: number): string {
  if (s < 0) s = 0
  if (s < 60) return s + 's'
  if (s < 3600) {
    const m = Math.floor(s / 60), sec = s % 60
    return sec === 0 ? m + 'm' : m + 'm' + String(sec).padStart(2, '0')
  }
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60)
  return m === 0 ? h + 'h' : h + 'h' + String(m).padStart(2, '0')
}

// The AgentStatus values: pending, idle and waiting are the engine's own, which
// the subagentStatusLine payload never carried. '' draws the glyph uncoloured.
const STATUS: Record<string, [string, string]> = {
  pending: ['', '…'], running: [CYAN, '▶'], waiting: [CYAN, '⏸'], idle: ['', '◌'],
  completed: [GREEN, '✔'], failed: [RED, '✘'], killed: [YELLOW, '■'],
}

// Whether the agent's turn is under way, so its elapsed time moves.
export function isLive(status: string): boolean {
  return status === 'running' || status === 'waiting'
}

// Status glyph in its colour, plus the elapsed seconds of a live agent.
export function statusSec(status: string, elapsed?: number): string {
  const g = Object.hasOwn(STATUS, status) ? STATUS[status] : undefined
  if (!g) return '?'
  const dur = isLive(status) && elapsed !== undefined ? ' ' + formatDur(elapsed) : ''
  if (!g[0]) return g[1] + dur
  return g[0] + g[1] + dur + RESET_FG
}

// "name (type)", or whichever of the two is present.
export function label(name: string, type: string): string {
  return name && type ? name + ' (' + type + ')' : name + type
}

const RANKS: Record<string, [string, string]> = {
  Fable: ['❶', MAGENTA], Opus: ['❷', YELLOW], Sonnet: ['❸', GREEN], Haiku: ['❹', RED],
}
const EFFORTS: Record<string, string> = { low: '○', medium: '◐', high: '●', xhigh: '◉', max: '◈' }

// Model rank and effort at the full or min level (statusline-design.md §4.17),
// or '' when neither is known. The effort is uncoloured.
export function modelSec(level: 'full' | 'min', name: string, effort: string): string {
  const el: string[] = []
  const fam = name.split(' ')[0] ?? ''
  const rank = name.includes(' ') && Object.hasOwn(RANKS, fam) ? RANKS[fam] : undefined
  if (rank) el.push(rank[1] + (level === 'full' ? rank[0] + ' ' + fam : rank[0]))
  else if (name) el.push(RED + name)
  const eg = Object.hasOwn(EFFORTS, effort) ? EFFORTS[effort] : ''
  if (eg) el.push(RESET_FG + (level === 'full' ? eg + ' ' + effort : eg))
  return el.length ? el.join(' ') + RESET_FG : ''
}

// A token count in three columns, as kilos: "  0", "999", " 5k", "117k".
// Thousands round half to even, as printf's %.0f.
export function kilos(n: number): string {
  if (n < 1000) return String(n).padStart(3)
  let q = Math.floor(n / 1000)
  const r = n % 1000
  if (r > 500 || (r === 500 && q % 2 === 1)) q++
  return String(q).padStart(2) + 'k'
}

export function tokenColor(n: number): string {
  return n < 50000 ? BLUE : n < 100000 ? GREEN : n < 150000 ? YELLOW : n < 200000 ? RED : BRMAGENTA
}

const RANGE = 50000
const BLOCKS = '▁▂▃▄▅▆▇█'
function barColor(i: number): string {
  return [BLUE, GREEN, YELLOW, RED][i] ?? (i % 2 ? MAGENTA : BRMAGENTA)
}

// The growth bar's width: one column per 50k range, at most 32; the elided form
// is 8 from 9 blocks up.
export function barWidth(n: number, elide = false): number {
  const w = Math.min(32, Math.ceil(n / RANGE))
  return elide && w > 8 ? 8 : w
}

// One block per 50k range, its height the fill within the range (▁ to █),
// coloured blue, green, yellow, red, then bright magenta and magenta in turn.
// Elided: the first five blocks, a ⋯, the last two (§4.12).
export function tokenBar(total: number, elide = false): string {
  if (!(total > 0)) return ''
  const n = barWidth(total)
  const cut = elide && n > 8
  let out = ''
  for (let i = 0; i < n; i++) {
    if (cut && i >= 5 && i < n - 2) {
      if (i === 5) out += BRMAGENTA + '⋯'
      continue
    }
    const fill = total - i * RANGE
    const idx = fill >= RANGE ? 8 : Math.min(7, Math.max(1, Math.floor((fill * 8 + RANGE / 2) / RANGE)))
    out += barColor(i) + BLOCKS[idx - 1]
  }
  return out + RESET_FG
}

// Visible width: code points outside CSI sequences.
export function visLen(s: string): number {
  return [...s.replace(/\x1b\[[^m]*m/g, '')].length
}

// Cut to max visible cells, as vis_truncate: escapes are kept, and a cut row
// ends in … drawn in the style of the cell it replaces.
export function visTruncate(s: string, max: number): string {
  const cps = [...s]
  let out = '', w = 0, pending = '', lastPre = '', lastSgr = '', tail = '', cut = false
  for (let i = 0; i < cps.length; i++) {
    if (cps[i] === '\x1b') {
      let j = i + 1
      if (cps[j] === '[') j++
      while (j < cps.length) {
        const b = cps[j]?.codePointAt(0) ?? 0
        if (b >= 0x40 && b <= 0x7e) break
        j++
      }
      const seq = cps.slice(i, j + 1).join('')
      if (cut) tail += seq
      else pending += seq
      i = j
    } else if (!cut && w < max) {
      lastPre = out
      lastSgr = pending
      out += pending + cps[i]
      pending = ''
      w++
    } else if (!cut) {
      cut = true
      tail += pending
      pending = ''
    }
  }
  if (!cut) return out + pending
  tail += pending
  return max > 0 ? lastPre + lastSgr + '…' + tail : tail
}

const join = (...parts: string[]): string => parts.filter(Boolean).join('  ')

export type RowAgent = {
  status: string
  name?: string
  type?: string
  model?: string
  effort?: unknown
  tokenCount?: number
  startTime?: number
}

// One row in columns cells: status, label, model and effort, context value and
// growth bar. Under pressure the bar is elided, then dropped; then model and
// effort shrink to glyphs; then the label is cut, then dropped; a plain cut is
// the last resort.
export function agentRow(a: RowAgent, columns: number | undefined, nowMs: number): string {
  const cols = Number.isInteger(columns) && columns! > 0 && columns! < 100000 ? columns! : 80
  const status = clean(a.status)
  let elapsed: number | undefined
  if (isLive(status) && Number.isSafeInteger(a.startTime) && a.startTime! >= 0 && Number.isFinite(nowMs)) {
    elapsed = Math.max(0, Math.floor(nowMs / 1000) - Math.floor(a.startTime! / 1000))
  }
  const st = statusSec(status, elapsed)
  const lab = label(clean(a.name), clean(a.type))
  const name = modelName(clean(a.model))
  const effort = clean(a.effort)
  const tok = Number.isSafeInteger(a.tokenCount) && a.tokenCount! >= 0 ? a.tokenCount! : undefined

  let ctx = '', nb = 0
  if (tok !== undefined) {
    ctx = tokenColor(tok) + ICON_CTX + ' ' + kilos(tok) + RESET_FG
    nb = barWidth(tok)
  }
  const pre = join(st, lab, modelSec('full', name, effort), ctx)
  const w0 = visLen(pre)
  if (w0 + (nb ? nb + 1 : 0) <= cols) return nb ? pre + ' ' + tokenBar(tok!) : pre
  const nbe = tok === undefined ? 0 : barWidth(tok, true)
  if (nbe < nb && w0 + 1 + nbe <= cols) return pre + ' ' + tokenBar(tok!, true)
  if (w0 <= cols) return pre
  const mmin = modelSec('min', name, effort)
  let row = join(st, lab, mmin, ctx)
  const w1 = visLen(row)
  if (w1 > cols && lab) {
    const room = cols - (w1 - visLen(lab))
    row = room >= 2 ? join(st, visTruncate(lab, room), mmin, ctx) : join(st, mmin, ctx)
  }
  return visTruncate(row, cols)
}
