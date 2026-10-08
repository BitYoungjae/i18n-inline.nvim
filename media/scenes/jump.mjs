// GIF: from a call to its line in the translation files, and back.
export default {
  kind: 'gif',
  project: 'web',
  args: ['src/billing/PlanCard.tsx'],
  cols: 96,
  rows: 25,
  async setup(s) {
    await s.command("call cursor(14, 1) | call search('cta', '', line('.'))")
  },
  async run(r) {
    await r.hold(1300)
    await r.keys(' ij', 800, { cast: ['Space', 'i', 'j'], label: 'Jump to the translation', castMs: 1500 })
    await r.wait(900) // the key's flash fades
    await r.hold(1400)
    await r.keys('<C-o>', 1000, { cast: ['Ctrl', 'O'], label: 'Back', castMs: 900 })
    await r.type(':I18nJump k')
    await r.keys('<Tab>', 600)
    await r.keys('<CR>', 800)
    await r.wait(900)
    await r.hold(1200)
    await r.keys('<C-o>', 1000, { cast: ['Ctrl', 'O'], label: 'Back', castMs: 900 })
    await r.type(':I18nJump!')
    await r.keys('<CR>', 3200)
  },
}
