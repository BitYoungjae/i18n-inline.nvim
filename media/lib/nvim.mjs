// A headless Neovim driven over msgpack-RPC, with a UI attached through the
// linegrid protocol. Screen keeps the composed grid (floats included, since
// ext_multigrid is off) so every recorded frame is exactly what a terminal
// UI would have drawn.

import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { attach } from 'neovim'

const here = path.dirname(fileURLToPath(import.meta.url))
export const INIT = path.join(here, '..', 'init.lua')

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

export class Screen {
  constructor() {
    this.cols = 0
    this.rows = 0
    this.grid = []
    this.hl = { 0: {} }
    this.colors = { fg: 0xc0caf5, bg: 0x1a1b26, sp: 0xff0000 }
    this.cursor = { row: 0, col: 0 }
    this.modes = []
    this.mode = 0
    this.busy = false
    this.flushes = 0
    this.lastEvent = 0
  }

  resize(cols, rows) {
    this.cols = cols
    this.rows = rows
    this.grid = Array.from({ length: rows }, () => this.blankRow())
  }

  blankRow() {
    return Array.from({ length: this.cols }, () => [' ', 0])
  }

  handle(batch) {
    this.lastEvent = Date.now()
    for (const [name, ...calls] of batch) {
      const fn = this['on_' + name]
      if (fn) for (const args of calls) fn.apply(this, args)
    }
  }

  on_default_colors_set(fg, bg, sp) {
    this.colors = { fg, bg, sp }
  }
  on_hl_attr_define(id, rgb) {
    this.hl[id] = rgb
  }
  on_grid_resize(_grid, w, h) {
    this.resize(w, h)
  }
  on_grid_clear() {
    this.grid = Array.from({ length: this.rows }, () => this.blankRow())
  }
  on_grid_cursor_goto(_grid, row, col) {
    this.cursor = { row, col }
  }
  on_grid_line(_grid, row, col, cells) {
    const line = this.grid[row]
    let hl = 0
    for (const [text, id, repeat] of cells) {
      if (id !== undefined) hl = id
      for (let i = 0; i < (repeat ?? 1); i++) line[col++] = [text, hl]
    }
  }
  on_grid_scroll(_grid, top, bot, left, right, rows) {
    const move = (dst, src) => {
      for (let c = left; c < right; c++) this.grid[dst][c] = this.grid[src][c]
    }
    if (rows > 0) for (let r = top; r < bot - rows; r++) move(r, r + rows)
    else for (let r = bot - 1; r >= top - rows; r--) move(r, r + rows)
    // vacated rows are redrawn by grid_line; fresh copies keep rows unshared
    for (let r = top; r < bot; r++) this.grid[r] = this.grid[r].slice()
  }
  on_mode_info_set(_enabled, infos) {
    this.modes = infos
  }
  on_mode_change(name, idx) {
    this.modeName = name
    this.mode = idx
  }
  on_busy_start() {
    this.busy = true
  }
  on_busy_stop() {
    this.busy = false
  }
  on_set_title(title) {
    this.title = title
  }
  on_flush() {
    this.flushes++
  }

  snapshot() {
    const info = this.modes[this.mode] || {}
    return {
      cols: this.cols,
      rows: this.rows,
      grid: this.grid.map((r) => r.map((c) => c.slice())),
      hl: { ...this.hl },
      colors: { ...this.colors },
      title: this.title || '',
      cursor: {
        ...this.cursor,
        shape: info.cursor_shape || 'block',
        percentage: info.cell_percentage || 100,
        visible: !this.busy,
      },
    }
  }
}

export class Session {
  constructor({ cwd, cols = 110, rows = 26, args = [], env = {} }) {
    Object.assign(this, { cwd, cols, rows, args, env })
    this.screen = new Screen()
  }

  async start() {
    this.proc = spawn('nvim', ['--embed', '--clean', '-u', INIT, ...this.args], {
      cwd: this.cwd,
      env: { ...process.env, ...this.env },
    })
    this.proc.stderr.on('data', (d) => process.stderr.write(d))
    this.nvim = attach({ proc: this.proc })
    this.nvim.on('notification', (method, args) => {
      if (method === 'redraw') this.screen.handle(args)
    })
    this.screen.resize(this.cols, this.rows)
    await this.nvim.uiAttach(this.cols, this.rows, { rgb: true, ext_linegrid: true })
    await this.settle(600)
  }

  // Wait until a redraw has been flushed and the UI has been quiet for
  // `quiet` ms (covers the plugin's debounce when it is long enough).
  async settle(quiet = 120, timeout = 3000) {
    const start = Date.now()
    const flushes = this.screen.flushes
    // Round-trip so queued input has been processed. Bounded: Neovim does
    // not answer while a hit-enter prompt is up, and the frame should show
    // that prompt rather than hang the render.
    await Promise.race([this.nvim.eval('1'), sleep(1500)])
    while (Date.now() - start < timeout) {
      const idle = Date.now() - this.screen.lastEvent
      if (idle >= quiet && (this.screen.flushes > flushes || Date.now() - start > quiet * 2)) break
      await sleep(10)
    }
  }

  input(keys) {
    return this.nvim.input(keys)
  }

  lua(code, args = []) {
    return this.nvim.lua(code, args)
  }

  command(cmd) {
    return this.nvim.command(cmd)
  }

  // `:qa!` never answers (the channel closes first), so just end the child.
  async stop() {
    this.proc.kill()
    await new Promise((r) => this.proc.once('exit', r))
  }
}
