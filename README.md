<p align="center">
  <img src="logo.jpeg" width="200" alt="Chewy">
</p>

<h1 align="center">Chewy</h1>

<p align="center">
  A terminal UI for AI image generation with Stable Diffusion, FLUX, DALL-E, Imagen, and more.
</p>

<p align="center">
  Built with the <a href="https://github.com/nicholasgasior/ruby-bubbletea">Charm Ruby</a> ecosystem (bubbletea, lipgloss, bubbles). Supports local generation via <a href="https://github.com/leejet/stable-diffusion.cpp">stable-diffusion.cpp</a> and 5 cloud providers.
</p>

---

## Install

```bash
brew install Holy-Coders/chewy/chewy
```

This installs both `chewy` and `sd` (the stable-diffusion.cpp inference engine with Metal GPU acceleration).

### Manual install

Requirements: Ruby 4.0+, [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp)

```bash
git clone https://github.com/Holy-Coders/chewy.git
cd chewy
bundle install
ruby chewy.rb
```

Set `SD_BIN` to point to your `sd` binary if it's not on your PATH.

## Usage

```bash
chewy
```

### Providers

Chewy supports 6 image generation backends. Press `^y` to switch providers.

| Provider | Models | Type |
|----------|--------|------|
| **Local (sd.cpp)** | SD 1.x/2.x/3.5, SDXL, FLUX (.gguf/.safetensors/.ckpt) | Local |
| **OpenAI** | GPT Image 1, DALL-E 3, DALL-E 2 | API |
| **Fireworks** | FLUX.1 Schnell/Dev/Pro, SDXL, Playground v2.5 | API |
| **Gemini** | Imagen 3, Imagen 3 Fast, Gemini 2.0 Flash | API |
| **HuggingFace** | FLUX.1 Schnell/Dev, SDXL, SD 3.5 Large, HiDream | API |
| **OpenAI-Compatible** | Any model via custom endpoint | API |

API keys are entered in-app (stored securely with chmod 600) or via environment variables (`OPENAI_API_KEY`, `FIREWORKS_API_KEY`, `GEMINI_API_KEY`, `HUGGINGFACE_API_KEY`).

### Keyboard shortcuts

| Key | Action |
|-----|--------|
| `tab` | Cycle focus between prompt, negative prompt, and params |
| `enter` | Generate image (when in prompt/negative) |
| `^y` | Switch provider |
| `^n` | Open model picker |
| `^d` | Download models from HuggingFace |
| `^t` | Theme picker (10 themes) |
| `^a` | Gallery |
| `^g` | Generation history |
| `^b` | Browse for init image (img2img) |
| `^v` | Paste image from clipboard (img2img) |
| `^u` | Clear init image |
| `^l` | LoRA selection |
| `^p` | Presets |
| `^e` | Open last image in viewer |
| `^f` | Fullscreen image preview |
| `^x` | Cancel generation |
| `^r` | Randomize seed |
| `^q` | Quit |

### Models

Place `.gguf`, `.safetensors`, or `.ckpt` model files in `~/models` (or set `CHEWY_MODELS_DIR`).

Chewy also scans for models from:
- **DiffusionBee** (`~/.diffusionbee`)
- **Draw Things** (`~/Library/Containers/com.liuliu.draw-things/Data/Documents/Models`)

Press `^d` inside chewy to browse recommended starter models or search HuggingFace directly. Curated picks include SD 1.5, SD 3.5 Medium, SDXL Turbo, DreamShaper, and FLUX.1 Schnell.

### FLUX models

FLUX models require companion files (clip_l, t5xxl, vae). Chewy will automatically download these when you first try to generate with a FLUX model. You'll need a [HuggingFace token](https://huggingface.co/settings/tokens) with read access.

### Themes

10 built-in color themes: Midnight (default), Dracula, Catppuccin, Tokyo Night, Gruvbox, Nord, Rose Pine, Solarized, Horizon, and Light. Press `^t` to switch. An animated pixel-art splash screen greets you on startup.

### Samplers & Schedulers

14 samplers (euler, euler_a, heun, dpm2, dpm++2s_a, dpm++2m, dpm++2mv2, ipndm, ipndm_v, lcm, ddim_trailing, tcd, res_multistep, res_2s) and 9 schedulers (discrete, karras, exponential, ays, gits, sgm_uniform, simple, smoothstep, kl_optimal). Configurable thread count for local generation.

### img2img

Press `^b` to browse for an input image, or `^v` to paste from clipboard. Adjust the `strength` parameter (0.0-1.0) to control how much the output differs from the input. Use `^u` to clear and go back to txt2img.

### Configuration

Config is stored at `~/.config/sdtui/config.yml`. You can also set:

| Env var | Description |
|---------|-------------|
| `SD_BIN` | Path to the `sd` binary |
| `CHEWY_MODELS_DIR` | Model directory (default: `~/models`) |
| `CHEWY_OUTPUT_DIR` | Output directory (default: `./outputs`) |
| `CHEWY_LORA_DIR` | LoRA directory (default: `~/loras`) |

## Contributing

### Setup

```bash
git clone https://github.com/Holy-Coders/chewy.git
cd chewy
bundle install
```

You'll need [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) built and on your PATH (or set `SD_BIN`):

```bash
git clone --recursive https://github.com/leejet/stable-diffusion.cpp
cd stable-diffusion.cpp
mkdir build && cd build
cmake .. -DSD_METAL=ON    # macOS with Metal GPU
cmake --build . --config Release
cp bin/sd-cli /usr/local/bin/sd
```

### Project structure

This is a single-file app:

- `chewy.rb` — the entire TUI application
- `Gemfile` / `Gemfile.lock` — Ruby dependencies
- `VERSION` — semver, read at runtime and used by CI for releases
- `Formula/` — Homebrew formulas (sd-cpp and chewy)
- `logo.jpeg` — the logo

### Dependencies

| Gem | Purpose |
|-----|---------|
| [bubbletea](https://rubygems.org/gems/bubbletea) | Elm Architecture TUI framework |
| [lipgloss](https://rubygems.org/gems/lipgloss) | Terminal styling and layout |
| [bubbles](https://rubygems.org/gems/bubbles) | TUI components (list, text input, spinner, progress) |
| [chunky_png](https://rubygems.org/gems/chunky_png) | PNG reading for terminal image rendering |

### Making changes

1. Fork the repo
2. Create a branch (`git checkout -b my-feature`)
3. Make your changes to `chewy.rb`
4. Test locally with `ruby chewy.rb`
5. Open a PR

### Releasing

Bump the version in `VERSION` and push to `main`. CI will automatically:
1. Create a GitHub release
2. Update the Homebrew formula with the new sha256

## License

[MIT](LICENSE) - Copyright (c) 2026 Holy Coders
