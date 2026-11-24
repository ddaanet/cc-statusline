import { describe, expect, test } from 'claude-code/testing'
import { envFromProbe, fableFile, fableLine, parseFable, stateDir } from './fable'

const H = (u?: string, r?: string): Record<string, string> => ({
  ...(u !== undefined && { 'anthropic-ratelimit-unified-7d_oi-utilization': u }),
  ...(r !== undefined && { 'anthropic-ratelimit-unified-7d_oi-reset': r }),
})

describe('parseFable', () => {
  test('a fraction becomes a whole percent beside the reset', async () => {
    expect(parseFable(H('0.42', '1795600800'))).toEqual({ percent: 42, resetsAt: 1795600800 })
  })
  test('rounds and caps at 100', async () => {
    expect(parseFable(H('0.995', '1795600800'))?.percent).toBe(100)
    expect(parseFable(H('1.7', '1795600800'))?.percent).toBe(100)
  })
  test('either header missing, or not a number, is no reading', async () => {
    expect(parseFable(H('0.4'))).toBeNull()
    expect(parseFable(H(undefined, '1795600800'))).toBeNull()
    expect(parseFable(H('x', '1795600800'))).toBeNull()
    expect(parseFable(H('0.4', ''))).toBeNull()
    expect(parseFable(H('-0.1', '1795600800'))).toBeNull()
    expect(parseFable(undefined)).toBeNull()
  })
  test('other windows are ignored', async () => {
    expect(parseFable({ 'anthropic-ratelimit-unified-7d-utilization': '0.4',
      'anthropic-ratelimit-unified-7d-reset': '1795600800' })).toBeNull()
  })
})

test('fableFile is per session, and refuses an id that could leave the dir', async () => {
  expect(fableFile('/s', '6f1c-ab')).toBe('/s/fable-6f1c-ab')
  expect(fableFile('/s', '../x')).toBeNull()
  expect(fableFile('/s', '')).toBeNull()
})

test('fableLine is one read-able line', async () => {
  expect(fableLine({ percent: 7, resetsAt: 1795600800 })).toBe('7 1795600800\n')
})

test('envFromProbe reads the three lines, an empty one unset', async () => {
  expect(envFromProbe('/s\n/x\n/h\n')).toEqual({ CC_STATUSLINE_STATE_DIR: '/s', XDG_RUNTIME_DIR: '/x', HOME: '/h' })
  expect(envFromProbe('\n\n/h\n')).toEqual({ HOME: '/h' })
  expect(stateDir(envFromProbe('\n\n/h\n'))).toBe('/h/.cache/cc-statusline')
  expect(envFromProbe('')).toEqual({})
})

describe('stateDir follows cc_state_dir_init', () => {
  test('explicit dir wins', async () => {
    expect(stateDir({ CC_STATUSLINE_STATE_DIR: '/s', XDG_RUNTIME_DIR: '/x', HOME: '/h' })).toBe('/s')
  })
  test('then XDG_RUNTIME_DIR, then HOME/.cache', async () => {
    expect(stateDir({ XDG_RUNTIME_DIR: '/x', HOME: '/h' })).toBe('/x/cc-statusline')
    expect(stateDir({ HOME: '/h' })).toBe('/h/.cache/cc-statusline')
    expect(stateDir({})).toBeNull()
  })
})
