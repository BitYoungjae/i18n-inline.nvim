// GIF: the two ways copy drifts, caught as they happen. Saving the JSON
// updates the component above; editing a fallback re-checks while typing.
export default {
  kind: 'gif',
  project: 'web',
  args: ['src/billing/PlanCard.tsx'],
  cols: 96,
  rows: 34,
  async setup(s) {
    await s.command('belowright split locales/en.json')
    await s.command('resize 13')
    await s.command('call search(\'"upgrade"\')')
    await s.command('normal! zz')
  },
  async run(r) {
    await r.hold(1600)
    await r.keys('$', 300)
    await r.keys('ci"', 350)
    await r.type('Start free trial')
    await r.keys('<Esc>', 700)
    await r.type(':w')
    await r.keys('<CR>', 2400, { quiet: 250 })
    await r.keys('<C-w>k', 500, { cast: ['Ctrl', 'W', 'K'], label: 'Back to the code', castMs: 1100 })
    await r.keys('10G0f,f\'', 500)
    await r.keys("ci'", 300)
    await r.type('Pick a plan', { quiet: 40 })
    await r.keys('<Esc>', 2800, { quiet: 300 })
  },
}
