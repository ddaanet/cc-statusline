import { describe, expect, test } from 'claude-code/testing'
import {
  agentRow, barWidth, CYAN, isLive, formatDur, ICON_CTX, kilos, modelName, RESET_FG, statusSec, tokenBar, visLen, YELLOW,
} from './agent-row'

const strip = (s: string): string => s.replace(/\x1b\[[0-9;]*m/g, '')
const T0 = 1_000_000_000_000
const NOW = T0 + 252_000
const opus = (cols: number | undefined, tokenCount = 116800) =>
  agentRow({ status: 'running', type: 'general-purpose', model: 'claude-opus-5-5', effort: 'high', tokenCount, startTime: T0 }, cols, NOW)
const PRE = '▶ 4m12  general-purpose  ❷ Opus ● high  ' + ICON_CTX + ' 117k'

describe('modelName', () => {
  test('ids map to display names', async () => {
    expect(modelName('claude-opus-5-5')).toBe('Opus 5.5')
    expect(modelName('claude-fable-5-1')).toBe('Fable 5.1')
    expect(modelName('claude-sonnet-4-5-20250929')).toBe('Sonnet 4.5')
    expect(modelName('claude-opus-4-8[1m]')).toBe('Opus 4.8')
    expect(modelName('claude-opus-5')).toBe('Opus 5')
    expect(modelName('claude-3-5-sonnet-20241022')).toBe('Sonnet 3.5')
    expect(modelName('gpt-something')).toBe('gpt-something')
    expect(modelName('')).toBe('')
  })
})

test('status glyphs, elapsed only while running or waiting', async () => {
  expect(statusSec('running', 252)).toBe(CYAN + '▶ 4m12' + RESET_FG)
  expect(statusSec('waiting', 252)).toBe(CYAN + '⏸ 4m12' + RESET_FG)
  expect(statusSec('idle', 252)).toBe('◌')
  expect(statusSec('pending', 252)).toBe('…')
  expect(statusSec('completed', 252)).not.toContain('4m12')
  expect(strip(statusSec('completed'))).toBe('✔')
  expect(strip(statusSec('failed'))).toBe('✘')
  expect(strip(statusSec('killed'))).toBe('■')
  expect(statusSec('paused')).toBe('?')
  expect(statusSec('constructor')).toBe('?')
})

test('durations read as format_turn_dur', async () => {
  expect(formatDur(0)).toBe('0s')
  expect(formatDur(59)).toBe('59s')
  expect(formatDur(60)).toBe('1m')
  expect(formatDur(65)).toBe('1m05')
  expect(formatDur(3600)).toBe('1h')
  expect(formatDur(3720)).toBe('1h02')
  expect(formatDur(-5)).toBe('0s')
})

test('kilos pads to three and rounds half to even', async () => {
  expect(kilos(0)).toBe('  0')
  expect(kilos(5000)).toBe(' 5k')
  expect(kilos(2500)).toBe(' 2k')
  expect(kilos(1500)).toBe(' 2k')
  expect(kilos(116800)).toBe('117k')
})

test('the bar is one column per 50k, elided from 9 blocks', async () => {
  expect(strip(tokenBar(116800))).toBe('██▃')
  expect(strip(tokenBar(1_000_000, true))).toBe('█████⋯██')
  expect(visLen(tokenBar(450_000, true))).toBe(barWidth(450_000, true))
  expect(tokenBar(0)).toBe('')
})

// The same row and widths the shell suite pinned for sa_row.
describe('width fitting', () => {
  test('wide: every element', async () => expect(strip(opus(200))).toBe(PRE + ' ██▃'))
  test('50 cols: the bar just fits', async () => expect(strip(opus(50))).toBe(PRE + ' ██▃'))
  test('49 cols: the bar goes first', async () => expect(strip(opus(49))).toBe(PRE))
  test('45 cols: then model and effort labels', async () =>
    expect(strip(opus(45))).toBe('▶ 4m12  general-purpose  ❷ ●  ' + ICON_CTX + ' 117k'))
  test('30 cols: then the label is cut', async () =>
    expect(strip(opus(30))).toBe('▶ 4m12  general-…  ❷ ●  ' + ICON_CTX + ' 117k'))
  test('20 cols: the label dropped', async () => expect(strip(opus(20))).toBe('▶ 4m12  ❷ ●  ' + ICON_CTX + ' 117k'))
  test('1M context: elided before dropped', async () =>
    expect(strip(opus(57, 1_000_000))).toBe('▶ 4m12  general-purpose  ❷ Opus ● high  ' + ICON_CTX + ' 1000k █████⋯██'))
  test('never wider than the columns', async () => {
    for (const c of [1, 5, 10, 15, 20, 24, 30, 40, 45, 49, 50, 51, 60, 80]) expect(visLen(opus(c))).toBeLessThanOrEqual(c)
  })
  test('no columns: 80', async () => expect(opus(undefined)).toBe(opus(80)))
})

test('only running and waiting are live', async () => {
  expect(['pending', 'running', 'waiting', 'idle', 'completed', 'failed', 'killed'].filter(isLive)).toEqual(['running', 'waiting'])
})

test('a waiting row keeps its time, an idle one has none', async () => {
  expect(strip(agentRow({ status: 'waiting', type: 'Explore', startTime: T0 }, 80, NOW))).toBe('⏸ 4m12  Explore')
  expect(strip(agentRow({ status: 'idle', name: 'mate', type: 'teammate', startTime: T0 }, 80, NOW))).toBe('◌  mate (teammate)')
})

test('effort: the last request first, then the agent setting', async () => {
  const row = (extra: object) => strip(agentRow({ status: 'running', model: 'claude-opus-5-5', startTime: T0, ...extra }, 80, NOW))
  expect(row({ lastRequest: { effort: 'xhigh' } })).toBe('▶ 4m12  ❷ Opus ◉ xhigh')
  expect(row({ effort: 'low', lastRequest: { effort: 'medium' } })).toBe('▶ 4m12  ❷ Opus ◐ medium')
  expect(row({ effort: 'low', lastRequest: {} })).toBe('▶ 4m12  ❷ Opus ○ low')
  expect(row({})).toBe('▶ 4m12  ❷ Opus')
})

test('missing fields drop their element', async () => {
  expect(strip(agentRow({ status: 'running', type: 'general-purpose', startTime: T0 }, 80, NOW))).toBe('▶ 4m12  general-purpose')
  expect(strip(agentRow({ status: 'running', model: 'claude-sonnet-5-5', effort: 16000, tokenCount: 5000, startTime: T0 }, 80, NOW)))
    .toBe('▶ 4m12  ❸ Sonnet  ' + ICON_CTX + '  5k ▁')
  expect(strip(agentRow({ status: 'failed', name: 'scout', type: 'Explore', effort: 'high', tokenCount: 0, startTime: T0 }, 80, NOW)))
    .toBe('✘  scout (Explore)  ● high  ' + ICON_CTX + '   0')
})

test('the gauge takes the line-1 value colour', async () => {
  expect(agentRow({ status: 'completed', type: 'x', tokenCount: 116800 }, 80, NOW)).toContain(YELLOW + ICON_CTX + ' 117k')
})

test('a name cannot inject escapes or line breaks', async () => {
  const row = agentRow({ status: 'completed', name: 'a\x1b[2mb\nc', type: 't' }, 80, NOW)
  expect(strip(row)).toBe('✔  a [2mb c (t)')
  expect(row.includes('\n')).toBe(false)
  expect(strip(agentRow({ status: 'completed', type: 'a\x9bb\u{202e}c' }, 80, NOW))).toBe('✔  a b c')
})

test('rows never change intensity', async () => {
  const rows = [1, 20, 45, 80, 200].flatMap(c => [opus(c), opus(c, 1_700_000),
    agentRow({ status: 'failed', name: 'n', type: 't', effort: 'max', tokenCount: 0 }, c, NOW)])
  for (const r of rows) for (const bad of ['\x1b[0m', '\x1b[1m', '\x1b[2m', '\x1b[22m', '\x1b[m']) expect(r.includes(bad)).toBe(false)
})
