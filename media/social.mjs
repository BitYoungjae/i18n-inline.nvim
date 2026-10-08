// Render the GitHub social preview (Settings > General > Social preview;
// GitHub has no API for it, so it is uploaded by hand) from social.html.
//
//   node social.mjs   # after `node render.mjs hero`
import { chromium } from 'playwright-core'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/usr/bin/chromium' })
const page = await browser.newPage({ viewport: { width: 1280, height: 640 } })
await page.goto(pathToFileURL(path.join(here, 'social.html')).href)
await page.evaluate(() => document.fonts.ready)
await page.locator('#card').screenshot({ path: path.join(here, '..', 'assets', 'social.png') })
await browser.close()
