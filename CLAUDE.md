# Chewy

Single-file Ruby TUI for local AI image generation using stable-diffusion.cpp.

## Architecture

- **Single file**: Everything is in `chewy.rb` (~2900 lines)
- **Framework**: Elm Architecture via bubbletea (init → update → view loop)
- **Rendering**: lipgloss for styling/layout, ChunkyPNG halfblocks for terminal images, Kitty graphics protocol for fullscreen
- **Async**: Returning a `Proc` from `update` runs it in `Thread.new`; returning a `Message` from the Proc routes it back through `update`

## Key patterns

- Overlays (`:models`, `:download`, `:gallery`, etc.) are managed via `@overlay` — set it to switch views, set nil to return to main
- Focus cycles between FOCUS_PROMPT (0), FOCUS_NEGATIVE (1), FOCUS_PARAMS (2) via tab
- Global keybindings are intercepted before forwarding to focused component
- Generation runs sd.cpp via `PTY.spawn` for unbuffered output parsing (step progress, seed, status)
- FLUX models need companion files (clip_l, t5xxl, vae) — auto-downloaded on first use

## Commands

- `ruby chewy.rb` — run the app locally
- `bundle install` — install dependencies
- `ruby -c chewy.rb` — syntax check

## Releasing

Bump `VERSION` file and push to main. CI creates a GitHub release and updates the Homebrew tap formula automatically.

## Important notes

- The bubbletea/lipgloss/bubbles gems have Rust native extensions shipped as precompiled platform-specific gems
- Kitty graphics escapes are only used in fullscreen mode because lipgloss miscounts their width
- Terminal cells are ~2:1 aspect ratio (height:width in pixels) — account for this in image sizing
- sd.cpp `--init-img` flag enables img2img mode, no separate `-M` flag needed
- Config lives at `~/.config/sdtui/config.yml`, presets at `~/.config/sdtui/presets.yml`
