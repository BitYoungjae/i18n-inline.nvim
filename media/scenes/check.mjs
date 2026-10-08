// GIF: audit the whole project into the quickfix list, then visit an item.
export default {
  kind: 'gif',
  project: 'web',
  args: ['src/billing/PlanCard.tsx'],
  cols: 96,
  rows: 30,
  async run(r) {
    await r.hold(1200)
    await r.type(':I18nCheck')
    await r.keys('<CR>', 2600, { quiet: 300 })
    await r.keys('<CR>', 2600, { quiet: 400 })
  },
}
