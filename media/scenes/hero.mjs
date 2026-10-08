// Still: inline values, drift and missing markers, and the language popover.
export default {
  kind: 'png',
  project: 'web',
  args: ['src/billing/PlanCard.tsx'],
  cols: 96,
  rows: 24,
  async run(r) {
    await r.keys('14G0f.b', 100)
    await r.keys(' ii', 400)
  },
}
