// GIF: cycle the inline display (always -> problems -> never) in a Flask
// app using gettext .po catalogs.
export default {
  kind: 'gif',
  project: 'api',
  args: ['app/billing/views.py'],
  cols: 96,
  rows: 28,
  async setup(s) {
    await s.command('call cursor(15, 1)')
  },
  async run(r) {
    await r.hold(1800)
    await r.keys(' ui', 1900, { cast: ['Space', 'u', 'i'], label: 'Only problems', castMs: 1500 })
    await r.keys(' ui', 1900, { cast: ['Space', 'u', 'i'], label: 'Hide all', castMs: 1500 })
    await r.keys(' ui', 1900, { cast: ['Space', 'u', 'i'], label: 'Show all', castMs: 1500 })
  },
}
