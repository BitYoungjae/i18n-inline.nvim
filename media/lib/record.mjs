// Scene recording: drive a Session with keystrokes and collect frames on a
// virtual timeline (each frame carries how long it stays on screen), so the
// output timing is scripted rather than whatever the machine happened to do.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { Session } from './nvim.mjs'

// Fixtures are copied under a throwaway HOME as ~/orbit/<project>, so every
// path Neovim or the plugin prints reads as a plausible user's project.
// Plugins and parsers are still found in the real home (see init.lua).
function stageFixtures(root) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'i18n-inline-home-'))
  fs.cpSync(new URL('fixtures', root).pathname, path.join(home, 'orbit'), { recursive: true })
  return home
}

export class Recorder {
  constructor(scene, root) {
    this.scene = scene
    this.home = stageFixtures(root)
    const data = path.join(os.homedir(), '.local', 'share', 'nvim')
    this.session = new Session({
      cwd: path.join(this.home, 'orbit', scene.project),
      cols: scene.cols,
      rows: scene.rows,
      args: scene.args,
      env: {
        HOME: this.home,
        DEMO_PLUGINS: process.env.DEMO_PLUGINS || path.join(data, 'lazy'),
        DEMO_PARSERS: process.env.DEMO_PARSERS || path.join(data, 'site'),
      },
    })
    this.frames = []
    this.castState = null // { keys, label, left }
  }

  async start() {
    await this.session.start()
    if (this.scene.setup) await this.scene.setup(this.session)
    await this.session.settle(300)
  }

  // Push the current screen for `ms` of playback, splitting it where an
  // on-screen keystroke caption expires.
  push(ms) {
    const snap = this.session.screen.snapshot()
    while (ms > 0) {
      const c = this.castState
      const span = c ? Math.min(ms, c.left) : ms
      this.frames.push({ ...snap, cast: c && { keys: c.keys, label: c.label }, ms: span })
      ms -= span
      if (c) {
        c.left -= span
        if (c.left <= 0) this.castState = null
      }
    }
  }

  async hold(ms, quiet = 120) {
    await this.session.settle(quiet)
    this.push(ms)
  }

  // Let real time pass without recording (timers, e.g. the jump flash).
  wait(ms) {
    return new Promise((r) => setTimeout(r, ms))
  }

  // Show a keystroke caption for the next `ms` of playback.
  cast(keys, label, ms = 1400) {
    this.castState = { keys, label, left: ms }
  }

  async keys(keys, ms = 500, opts = {}) {
    if (opts.cast) this.cast(opts.cast, opts.label, opts.castMs)
    await this.session.input(keys)
    await this.hold(ms, opts.quiet ?? 120)
  }

  // Type text one key at a time with a human-ish, deterministic rhythm.
  async type(text, { base = 55, jitter = 35, quiet = 25 } = {}) {
    let seed = text.length * 7919
    for (const ch of text) {
      seed = (seed * 1103515245 + 12345) % 2147483648
      const key = ch === '<' ? '<lt>' : ch === ' ' ? '<Space>' : ch
      await this.session.input(key)
      await this.session.settle(quiet)
      this.push(base + (seed % jitter))
    }
  }

  async stop() {
    await this.session.stop()
    fs.rmSync(this.home, { recursive: true, force: true })
  }
}
