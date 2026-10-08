# README media

The screenshots and GIFs in `../assets/` are recorded from a real Neovim,
not mocked up. `render.mjs` starts `nvim --embed` with `init.lua`, attaches
as a UI over msgpack-RPC, plays a scripted scene, and paints every frame of
the screen grid in headless Chromium. ffmpeg turns the frames into GIFs.

```sh
cd media
npm install
node render.mjs            # every scene
node render.mjs hover      # one scene
```

You need Node 20+, ffmpeg, Chromium (`CHROMIUM=/path` if it isn't in
`/usr/bin`) and these, which the config borrows from an existing install
instead of vendoring:

- `DEMO_PLUGINS` (default `~/.local/share/nvim/lazy`): `tokyonight.nvim`,
  `lualine.nvim`, `nvim-web-devicons`, `nvim-treesitter` (queries only)
- `DEMO_PARSERS` (default `~/.local/share/nvim/site`): a `parser/` directory
  with `tsx`, `typescript`, `json` and `python`
- `.cache/fonts/`: JetBrainsMono Nerd Font (`Regular`, `Bold`, `Italic`,
  `BoldItalic` `.ttf`) from the
  [Nerd Fonts releases](https://github.com/ryanoasis/nerd-fonts/releases)

## Layout

- `scenes/*.mjs`: one file per asset. `kind` is `png` or `gif`; `run()`
  sends keys and decides how long each state stays on screen.
- `fixtures/`: the made-up projects the scenes open. They are copied to a
  temporary `$HOME` as `~/orbit/<name>` so paths on screen look ordinary.
- `lib/nvim.mjs`: the Neovim process and the screen grid model.
- `lib/record.mjs`: the scene API (`keys`, `type`, `hold`, `wait`, `cast`).
- `lib/output.mjs`, `stage.html`: frame painting and GIF encoding.

`node social.mjs` renders `../assets/social.png` from `social.html` (run
it after the hero scene). It is the repository's social preview, which
GitHub only takes as an upload under Settings → General.

Timing is scripted, not measured: a frame lasts as long as the scene says,
however long Neovim took to draw it. Use `wait(ms)` when a real timer has
to run out first, such as the highlight after a jump.
