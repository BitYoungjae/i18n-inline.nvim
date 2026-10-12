// GIF: read the same component in another language for the session.
export default {
  kind: 'gif',
  project: 'web',
  args: ['src/billing/PlanCard.tsx'],
  cols: 100,
  rows: 25,
  async setup(s) {
    await s.command("call cursor(13, 1) | call search('seats', '', line('.'))")
  },
  async run(r) {
    await r.hold(1600)
    await r.keys(' il', 1100, { cast: ['Space', 'i', 'l'], label: 'Pick a language', castMs: 1600 })
    await r.keys('j', 340)
    await r.keys('j', 700)
    await r.keys('<CR>', 3600, { cast: ['Enter'], label: 'Japanese, in every buffer', castMs: 1600, quiet: 300 })
    await r.type(':I18nLang e')
    await r.keys('<Tab>', 700)
    await r.keys('<CR>', 2600, { quiet: 300 })
  },
}
