<p align="center">
  <img src="logo.jpeg" width="200" alt="Chewy">
</p>

<h1 align="center">Chewy</h1>

<p align="center">
  A terminal UI for local AI image generation with Stable Diffusion and FLUX.
</p>

<p align="center">
  Built with the <a href="https://github.com/nicholasgasior/ruby-bubbletea">Charm Ruby</a> ecosystem (bubbletea, lipgloss, bubbles) and <a href="https://github.com/leejet/stable-diffusion.cpp">stable-diffusion.cpp</a>.
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

### Keyboard shortcuts

| Key | Action |
|-----|--------|
| `tab` | Cycle focus between prompt, negative prompt, and params |
| `enter` | Generate image (when in prompt/negative) |
| `^n` | Open model picker |
| `^d` | Download models from HuggingFace |
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

Press `^d` inside chewy to browse and download models directly from HuggingFace.

### FLUX models

FLUX models require companion files (clip_l, t5xxl, vae). Chewy will automatically download these when you first try to generate with a FLUX model. You'll need a [HuggingFace token](https://huggingface.co/settings/tokens) with read access.

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
