# Chewy

Ruby TUI for local AI image generation using stable-diffusion.cpp.

## Architecture

- **Entrypoint**: `chewy.rb` (~40 lines) — CLI routing + app launch
- **Orchestrator**: `lib/chewy.rb` (~300 lines) — requires, Chewy class with `initialize`, `init`, `update`, `view`
- **Modules**: `lib/chewy/*.rb` — mixed into the Chewy class via `include`
- **Framework**: Elm Architecture via bubbletea (init → update → view loop)
- **Rendering**: lipgloss for styling/layout, ChunkyPNG halfblocks for terminal images, Kitty graphics protocol for fullscreen
- **Async**: Returning a `Proc` from `update` runs it in `Thread.new`; returning a `Message` from the Proc routes it back through `update`

## File Structure

```
chewy.rb                    # Entrypoint: CLI routing, update check, Bubbletea.run
lib/
  chewy.rb                  # Chewy class: initialize, init, update, view + module includes
  chewy/
    constants.rb            # All data constants: VERSION, URLs, PRESETS, MODEL_FAMILIES, etc.
    theme.rb                # THEMES hash + Theme module (gradient, accessors)
    messages.rb             # All ~20 message structs for async operations
    providers.rb            # Provider::Base + all 6 provider classes
    config.rb               # Module: load/save config, presets, build_providers
    models.rb               # Module: model scanning, detection, pinning, FLUX support
    loras.rb                # Module: LoRA scanning, filtering, compatibility, selection
    generation.rb           # Module: start_generation, prompt history
    input_handling.rb       # Module: key/mouse handlers, focus, clipboard
    overlays.rb             # Module: overlay state management + key handlers for all overlays
    downloads.rb            # Module: download browser (models + LoRAs)
    rendering.rb            # Module: main view layout, header, params, prompt, preview, toasts
    overlay_rendering.rb    # Module: render methods for all overlay views
    image_rendering.rb      # Module: halfblocks, kitty protocol, logo rendering, utilities
    cli.rb                  # CLI commands: list, delete, help, logo, update check
```

16 files total. Flat `lib/chewy/` directory, no nesting.

### Module pattern

The Chewy class has ~220 instance variables accessed across methods. Rather than extracting separate classes (which would require massive state plumbing), Ruby modules are mixed into the Chewy class — each module gets direct access to all instance variables:

```ruby
class Chewy
  include Bubbletea::Model
  include Config
  include Models
  include Loras
  include Generation
  include InputHandling
  include Overlays
  include Downloads
  include Rendering
  include OverlayRendering
  include ImageRendering
end
```

## Key patterns

- Overlays (`:models`, `:download`, `:gallery`, etc.) are managed via `@overlay` — set it to switch views, set nil to return to main
- Focus cycles between FOCUS_PROMPT (0), FOCUS_NEGATIVE (1), FOCUS_PARAMS (2) via tab
- Global keybindings are intercepted before forwarding to focused component
- Generation runs sd.cpp via `PTY.spawn` for unbuffered output parsing (step progress, seed, status)
- FLUX models need companion files (clip_l, t5xxl, vae) — auto-downloaded on first use
- `CHEWY_ROOT` is defined in `lib/chewy.rb` as the project root — use it for resolving asset paths (VERSION, logo.png, bin/sd)

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
- Config lives at `~/.config/chewy/config.yml`, presets at `~/.config/chewy/presets.yml`
