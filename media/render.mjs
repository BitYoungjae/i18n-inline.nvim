// Render the README media from a real headless Neovim.
//
//   npm install
//   node render.mjs            # every scene
//   node render.mjs hover jump # some scenes
//
// Output lands in ../assets/. See README.md in this directory.

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { Recorder } from './lib/record.mjs'
import { paint, writeGif, writePng } from './lib/output.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = pathToFileURL(here + '/')
const assets = path.join(here, '..', 'assets')
const stageUrl = new URL('stage.html', root).href

const all = fs
  .readdirSync(path.join(here, 'scenes'))
  .filter((f) => f.endsWith('.mjs'))
  .map((f) => f.replace(/\.mjs$/, ''))
  .sort()
const wanted = process.argv.slice(2)
const names = wanted.length ? wanted : all

for (const name of names) {
  const scene = (await import(`./scenes/${name}.mjs`)).default
  const t0 = Date.now()
  const rec = new Recorder(scene, root)
  await rec.start()
  try {
    await scene.run(rec)
  } finally {
    await rec.stop()
  }
  const shots = await paint(scene, rec.frames, stageUrl, { scale: scene.scale ?? 2 })
  const out = path.join(assets, `${name}.${scene.kind}`)
  if (scene.kind === 'png') writePng(shots[shots.length - 1], out)
  else writeGif(shots, out, { width: scene.width })
  const kb = Math.round(fs.statSync(out).size / 1024)
  process.stdout.write(`${name}: ${shots.length} frames, ${kb} KB, ${Date.now() - t0} ms\n`)
}
process.exit(0)
