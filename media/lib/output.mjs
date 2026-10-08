// Frames -> pixels: paint each frame on the stage page in Chromium, then
// encode PNG stills or an optimized GIF with ffmpeg.

import { chromium } from 'playwright-core'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const CURSOR = '#c0caf5'

function findChromium() {
  if (process.env.CHROMIUM) return process.env.CHROMIUM
  for (const p of ['/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome']) {
    if (fs.existsSync(p)) return p
  }
  throw new Error('Chromium not found; set CHROMIUM=/path/to/chrome')
}

// Merge consecutive identical frames into one longer frame.
function dedupe(frames) {
  const out = []
  let lastKey = null
  for (const f of frames) {
    const { ms, ...rest } = f
    const key = JSON.stringify(rest)
    if (key === lastKey) out[out.length - 1].ms += ms
    else out.push({ ...f })
    lastKey = key
  }
  return out
}

export async function paint(scene, frames, stageUrl, { scale = 2 } = {}) {
  const browser = await chromium.launch({ executablePath: findChromium() })
  const page = await browser.newPage({ deviceScaleFactor: scale, viewport: { width: 2400, height: 1600 } })
  await page.goto(stageUrl)
  const first = frames[0]
  await page.evaluate((o) => window.setup(o), {
    cols: first.cols,
    rows: first.rows,
    bg: first.colors.bg,
    casting: frames.some((f) => f.cast),
  })
  const stage = await page.$('#stage')
  const shots = []
  for (const f of dedupe(frames)) {
    await page.evaluate((fr) => window.draw(fr), { ...f, cursorColor: CURSOR })
    shots.push({ png: await stage.screenshot({ type: 'png' }), ms: f.ms })
  }
  await browser.close()
  return shots
}

export function writePng(shot, out) {
  fs.writeFileSync(out, shot.png)
}

export function writeGif(shots, out, { width } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'i18n-inline-media-'))
  let list = 'ffconcat version 1.0\n'
  shots.forEach((s, i) => {
    const name = `f${String(i).padStart(4, '0')}.png`
    fs.writeFileSync(path.join(dir, name), s.png)
    // GIF delays are centiseconds
    // per-file framerate: the image demuxer's default 25 fps would round
    // every duration to 40 ms
    list += `file '${name}'\noption framerate 100\nduration ${(Math.max(2, Math.round(s.ms / 10)) / 100).toFixed(2)}\n`
  })
  // The concat demuxer ignores the last entry's duration, so the final
  // frame would flash by: close the timeline with a 10 ms copy of it.
  list += `file 'f${String(shots.length - 1).padStart(4, '0')}.png'\noption framerate 100\nduration 0.01\n`
  fs.writeFileSync(path.join(dir, 'list.txt'), list)
  const scaleF = width ? `scale=${width}:-1:flags=lanczos,` : ''
  execFileSync('ffmpeg', [
    '-y', '-loglevel', 'error',
    '-f', 'concat', '-safe', '0', '-i', path.join(dir, 'list.txt'),
    '-vf', `${scaleF}split[a][b];[a]palettegen=max_colors=256:stats_mode=full:reserve_transparent=0[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle`,
    '-fps_mode', 'vfr',
    '-enc_time_base', '1/100',
    '-loop', '0',
    out,
  ])
  fs.rmSync(dir, { recursive: true, force: true })
}
