import type { EngineInterface, Register } from 'claude-code'
import { ENV_PROBE, envFromProbe, fableFile, fableLine, parseFable, stateDir } from './fable'

// The state dir, or '' when unusable. The mod never creates it: the statusline
// does, 0700 and owner-checked, so the mod only writes into a real directory
// that is not a symlink.
async function resolveDir($: EngineInterface): Promise<string> {
  const run = await $.process.run([...ENV_PROBE])
  const d = run.exitCode === 0 ? stateDir(envFromProbe(run.stdout)) : null
  if (!d) return ''
  const st = await $.fs.stat(d, { resolve: true }).catch(() => undefined)
  if (!st || st.kind !== 'dir' || st.isLink || st.realPath !== d.replace(/\/+$/, '')) return ''
  return d
}

export const register: Register = on => {
  // The last file and line written: a session id that changes under the same
  // module (/clear, /resume) names a new file, so the pair is the key.
  let lastKey = ''

  on('session.start', async ($, e, next) => {
    const res = await next(e)
    // Files of sessions whose window has long reset: past 8 days none can be
    // read (a window is 7), so drop them. Best effort.
    try {
      const d = await resolveDir($)
      if (d) await $.process.run(['find', d, '-maxdepth', '1', '-type', 'f', '-name', 'fable-*', '-mtime', '+8', '-delete'])
    } catch {
      // Pruning is housekeeping only.
    }
    return res
  })

  on('http.fetch', async ($, e, next) => {
    const res = await next(e)
    if (next.origin.plugin !== 'engine') return res
    try {
      const headers = 'value' in res ? res.value?.headers : undefined
      const fable = parseFable(headers)
      if (!fable) return res
      const line = fableLine(fable)
      const id = await $.session.id()
      if (`${id} ${line}` === lastKey) return res
      const d = await resolveDir($)
      const target = d ? fableFile(d, id) : null
      if (!target) return res
      await $.fs.write(target, line)
      lastKey = `${id} ${line}`
    } catch {
      // Reading the headers must never touch the model request.
    }
    return res
  })
}
