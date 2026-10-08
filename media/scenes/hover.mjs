// GIF: walk down the component and open the language popover twice.
export default {
  kind: 'gif',
  project: 'web',
  args: ['src/billing/PlanCard.tsx'],
  cols: 96,
  rows: 25,
  async run(r) {
    await r.hold(1200)
    for (let i = 0; i < 9; i++) await r.keys('j', 70)
    await r.keys("0f'l", 450)
    await r.keys(' ii', 2600, { cast: ['Space', 'i', 'i'], label: 'Show every language', castMs: 1500 })
    for (let i = 0; i < 4; i++) await r.keys('j', 110)
    await r.keys("0f'l", 450)
    await r.keys(' ii', 3200, { cast: ['Space', 'i', 'i'], label: 'Show every language', castMs: 1500 })
    await r.keys('k', 900)
  },
}
