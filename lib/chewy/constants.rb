# frozen_string_literal: true

CHEWY_VERSION = File.read(File.join(CHEWY_ROOT, "VERSION")).strip rescue "0.0.0"
CHEWY_REPO = "Holy-Coders/chewy"

HF_API_BASE = "https://huggingface.co/api"
HF_DOWNLOAD_BASE = "https://huggingface.co"
CIVITAI_API_BASE = "https://civitai.com/api/v1"
MODEL_EXTENSIONS = %w[.gguf .safetensors .ckpt .pth].freeze
DOWNLOAD_SOURCES = [:huggingface, :civitai].freeze

# Filename prefixes for companion/auxiliary files — excluded from model file listings
COMPANION_FILE_PATTERNS = %w[clip_l t5xxl umt5 ae clip_vision wan_2.1_vae flux2_ae flux2-vae qwen3- qwen2.5-vl qwen_image_vae taesd taef1 taesdxl realesrgan].freeze

# ESRGAN upscaler model — 4x Real-ESRGAN, public mirror
ESRGAN_MODEL = {
  filename: "RealESRGAN_x4plus.pth",
  url: "https://huggingface.co/leonelhs/realesrgan/resolve/main/RealESRGAN_x4plus.pth",
  scale: 4,
}.freeze

# TAESD decoder files — used for fast preview instead of --preview proj when present.
# Architecture → filename glob. First match wins.
TAESD_FILES = {
  flux:  %w[taef1*.safetensors taef1*.gguf],
  sdxl:  %w[taesdxl*.safetensors taesdxl*.gguf],
  sd:    %w[taesd*.safetensors taesd*.gguf],
}.freeze

# HuggingFace repo patterns known to be incompatible with sd.cpp
INCOMPATIBLE_HF_PATTERNS = %w[whisper llama mistral phi gemma qwen deepseek codellama].freeze

# Common macOS app model directories
EXTRA_MODEL_DIRS = [
  File.expand_path("~/.diffusionbee"),
  File.expand_path("~/Library/Containers/com.liuliu.draw-things/Data/Documents/Models"),
].freeze
SAMPLER_OPTIONS = %w[euler euler_a heun dpm2 dpm++2s_a dpm++2m dpm++2mv2 ipndm ipndm_v lcm ddim_trailing tcd res_multistep res_2s].freeze
SCHEDULER_OPTIONS = %w[discrete karras exponential ays gits sgm_uniform simple smoothstep kl_optimal].freeze
OLD_CONFIG_DIR = File.expand_path("~/.config/sdtui")
CONFIG_DIR = File.expand_path("~/.config/chewy")
# Migrate from old config dir if new one doesn't exist yet
if !File.directory?(CONFIG_DIR) && File.directory?(OLD_CONFIG_DIR)
  FileUtils.cp_r(OLD_CONFIG_DIR, CONFIG_DIR)
end
CONFIG_PATH = File.join(CONFIG_DIR, "config.yml")
PRESETS_PATH = File.join(CONFIG_DIR, "presets.yml")

BUILTIN_PRESETS = {
  # --- Generate from scratch ---
  "Quick Draft" => { "desc" => "Fast preview — see your idea in seconds", "steps" => 10, "cfg_scale" => 7.0, "width" => 512, "height" => 512, "sampler" => "euler", "scheduler" => "ays", "model_type" => "sd" },
  "Balanced" => { "desc" => "Good quality, reasonable speed", "steps" => 20, "cfg_scale" => 7.0, "width" => 512, "height" => 512, "sampler" => "euler_a", "scheduler" => "karras", "model_type" => "sd" },
  "High Quality" => { "desc" => "Detailed output, larger canvas", "steps" => 30, "cfg_scale" => 7.0, "width" => 768, "height" => 768, "sampler" => "dpm++2m", "scheduler" => "karras", "model_type" => "sd" },
  "Max Quality" => { "desc" => "Best possible output (SDXL, slow)", "steps" => 50, "cfg_scale" => 7.5, "width" => 1024, "height" => 1024, "sampler" => "dpm++2m", "scheduler" => "karras", "model_type" => "sdxl" },
  # --- Aspect ratios ---
  "Portrait" => { "desc" => "Tall frame — people, characters, headshots", "steps" => 25, "cfg_scale" => 7.0, "width" => 512, "height" => 768, "sampler" => "euler_a", "scheduler" => "karras", "model_type" => "sd" },
  "Landscape" => { "desc" => "Wide frame — scenery, environments", "steps" => 25, "cfg_scale" => 7.0, "width" => 768, "height" => 512, "sampler" => "euler_a", "scheduler" => "karras", "model_type" => "sd" },
  "Widescreen (16:9)" => { "desc" => "Cinema format — wallpapers, banners", "steps" => 25, "cfg_scale" => 7.0, "width" => 896, "height" => 512, "sampler" => "dpm++2m", "scheduler" => "karras" },
  "Square HD" => { "desc" => "1024x1024 square (SDXL)", "steps" => 25, "cfg_scale" => 7.0, "width" => 1024, "height" => 1024, "sampler" => "dpm++2m", "scheduler" => "karras", "model_type" => "sdxl" },
  # --- Edit an image (SD/SDXL) ---
  "Edit — Quick Touch-up" => { "desc" => "Fast light edits to an existing image", "steps" => 20, "cfg_scale" => 7.0, "strength" => 0.5, "sampler" => "euler_a", "scheduler" => "karras" },
  "Edit — Refine Details" => { "desc" => "Higher quality edits, keeps most of the original", "steps" => 35, "cfg_scale" => 7.0, "strength" => 0.65, "sampler" => "dpm++2m", "scheduler" => "karras" },
  "Edit — Major Rework" => { "desc" => "Big changes — new style, heavy modifications", "steps" => 30, "cfg_scale" => 8.0, "strength" => 0.85, "sampler" => "euler_a", "scheduler" => "karras" },
  "Edit — Subtle Tweak" => { "desc" => "Minimal change — color correction, small fixes", "steps" => 25, "cfg_scale" => 7.0, "strength" => 0.3, "sampler" => "dpm++2m", "scheduler" => "karras" },
  # --- ControlNet (face/structure preservation) ---
  "Keep Face, Change Rest" => { "desc" => "ControlNet locks edges — change clothes, background, style", "steps" => 30, "cfg_scale" => 7.0, "width" => 512, "height" => 512, "strength" => 0.4, "sampler" => "euler_a", "scheduler" => "karras", "model_type" => "sd", "cn_strength" => 0.85, "cn_canny" => true },
  "Restyle (keep structure)" => { "desc" => "New art style but same composition and layout", "steps" => 30, "cfg_scale" => 7.5, "width" => 512, "height" => 512, "strength" => 0.65, "sampler" => "dpm++2m", "scheduler" => "karras", "model_type" => "sd", "cn_strength" => 0.7, "cn_canny" => true },
  "Creative Remix" => { "desc" => "Loose structural guide — big creative changes", "steps" => 35, "cfg_scale" => 8.0, "width" => 512, "height" => 512, "strength" => 0.8, "sampler" => "euler_a", "scheduler" => "karras", "model_type" => "sd", "cn_strength" => 0.5, "cn_canny" => true },
  # --- FLUX editing ---
  "FLUX — Keep Face (safe)" => { "desc" => "Minimal changes, face stays recognizable", "steps" => 40, "cfg_scale" => 1.0, "strength" => 0.35, "guidance" => 4.5, "sampler" => "euler", "scheduler" => "simple", "model_type" => "flux" },
  "FLUX — Keep Face (stronger)" => { "desc" => "More visible changes, face may shift slightly", "steps" => 40, "cfg_scale" => 1.0, "strength" => 0.45, "guidance" => 5.5, "sampler" => "euler", "scheduler" => "simple", "model_type" => "flux" },
  "FLUX — Light Edit" => { "desc" => "Subtle adjustments with FLUX quality", "steps" => 28, "cfg_scale" => 1.0, "strength" => 0.5, "guidance" => 5.0, "sampler" => "euler", "scheduler" => "simple", "model_type" => "flux" },
  "FLUX — Balanced Edit" => { "desc" => "Good mix of change and preservation", "steps" => 28, "cfg_scale" => 1.0, "strength" => 0.75, "guidance" => 7.0, "sampler" => "euler", "scheduler" => "simple", "model_type" => "flux" },
  "FLUX — Full Restyle" => { "desc" => "Major transformation — prompt drives everything", "steps" => 35, "cfg_scale" => 1.0, "strength" => 0.9, "guidance" => 10.0, "sampler" => "euler", "scheduler" => "simple", "model_type" => "flux" },
  # --- Inpainting (selective editing) ---
  "Inpaint — Protect Face" => { "desc" => "Auto-masks center — change background/clothes, keep face", "steps" => 30, "cfg_scale" => 7.0, "width" => 512, "height" => 512, "strength" => 0.75, "sampler" => "euler_a", "scheduler" => "karras", "model_type" => "sd", "auto_mask" => "center_preserve" },
  "Inpaint — New Background" => { "desc" => "Replace everything around the subject", "steps" => 35, "cfg_scale" => 7.5, "width" => 512, "height" => 512, "strength" => 0.85, "sampler" => "dpm++2m", "scheduler" => "karras", "model_type" => "sd", "auto_mask" => "center_preserve" },
  # --- FLUX from scratch ---
  "FLUX — Fast" => { "desc" => "Quick FLUX generation in 4 steps", "steps" => 4, "cfg_scale" => 1.0, "width" => 512, "height" => 512, "sampler" => "euler", "scheduler" => "simple", "model_type" => "flux" },
  "FLUX — Balanced" => { "desc" => "Good FLUX quality at 1024x1024", "steps" => 8, "cfg_scale" => 1.0, "width" => 1024, "height" => 1024, "sampler" => "euler", "scheduler" => "simple", "model_type" => "flux" },
  "FLUX — High Quality" => { "desc" => "Best FLUX output, more steps", "steps" => 20, "cfg_scale" => 1.0, "width" => 1024, "height" => 1024, "sampler" => "euler", "scheduler" => "simple", "model_type" => "flux" },
  # --- Video (Wan) ---
  "Video — Quick Preview" => { "desc" => "Fast 8-frame test (1s)", "steps" => 10, "cfg_scale" => 5.0, "width" => 384, "height" => 672, "video_frames" => 9, "fps" => 8, "sampler" => "euler", "scheduler" => "simple", "model_type" => "wan" },
  "Video — Standard" => { "desc" => "Good quality 2s clip", "steps" => 15, "cfg_scale" => 5.0, "width" => 384, "height" => 672, "video_frames" => 17, "fps" => 8, "sampler" => "euler", "scheduler" => "simple", "model_type" => "wan" },
  "Video — High Quality" => { "desc" => "Detailed 2s video at 480p", "steps" => 20, "cfg_scale" => 5.0, "width" => 480, "height" => 832, "video_frames" => 33, "fps" => 16, "sampler" => "euler", "scheduler" => "simple", "model_type" => "wan" },
  "Video — Img2Vid" => { "desc" => "Animate an image into video", "steps" => 15, "cfg_scale" => 5.0, "width" => 384, "height" => 672, "video_frames" => 17, "fps" => 8, "strength" => 0.75, "sampler" => "euler", "scheduler" => "simple", "model_type" => "wan" },
  # --- Styles ---
  "Photorealistic" => { "desc" => "Lifelike photos — portraits, products, scenes", "steps" => 35, "cfg_scale" => 5.0, "width" => 768, "height" => 768, "sampler" => "dpm++2m", "scheduler" => "karras" },
  "Artistic / Painterly" => { "desc" => "Oil painting, watercolor, illustrated look", "steps" => 30, "cfg_scale" => 10.0, "width" => 768, "height" => 768, "sampler" => "euler_a", "scheduler" => "karras" },
  "Pixel Art" => { "desc" => "Retro game-style pixel art", "steps" => 20, "cfg_scale" => 8.0, "width" => 512, "height" => 512, "sampler" => "euler", "scheduler" => "discrete" },
}.freeze

# ---------- Model Families ----------

# Each model family groups related architectures and defines compatibility boundaries.
# LoRAs are only compatible within the same family (or explicitly listed compatible_models).
MODEL_FAMILIES = {
  "SD 1.x" => {
    label: "Stable Diffusion 1.x",
    aliases: ["SD 1.5", "SD 1.4", "SD1", "sd15"],
    description: "Classic SD — fast, low VRAM, huge LoRA ecosystem",
    default_resolution: [512, 512],
  },
  "SD 2.x" => {
    label: "Stable Diffusion 2.x",
    aliases: ["SD 2.0", "SD 2.1", "sd2"],
    description: "SD v2 — 768px native, fewer LoRAs available",
    default_resolution: [768, 768],
  },
  "SDXL" => {
    label: "Stable Diffusion XL",
    aliases: ["SDXL 1.0", "SDXL Turbo", "sdxl"],
    description: "SDXL — high quality 1024px, growing LoRA support",
    default_resolution: [1024, 1024],
  },
  "SD3" => {
    label: "Stable Diffusion 3",
    aliases: ["SD 3.5", "sd3"],
    description: "Newest SD architecture — excellent quality",
    default_resolution: [1024, 1024],
  },
  "FLUX" => {
    label: "FLUX",
    aliases: ["FLUX.1", "flux-schnell", "flux-dev"],
    description: "State-of-the-art — needs companion files",
    default_resolution: [1024, 1024],
  },
  "FLUX2" => {
    label: "FLUX.2",
    aliases: ["FLUX.2", "flux-2", "flux2", "flux-2-klein", "flux-2-dev", "klein"],
    description: "FLUX.2 Klein/Dev — uses Qwen3 text encoder, different from FLUX.1",
    default_resolution: [1024, 1024],
  },
  "Chroma" => {
    label: "Chroma",
    aliases: ["chroma", "chroma-unlocked", "chroma1", "chroma-radiance"],
    description: "Chroma — FLUX-derived, runs on 4-6GB VRAM, reuses FLUX.1 t5xxl+vae",
    default_resolution: [1024, 1024],
  },
  "Z-Image" => {
    label: "Z-Image",
    aliases: ["z-image", "z_image", "zimage"],
    description: "Z-Image — low-VRAM model (4GB), Qwen3-4B text encoder",
    default_resolution: [1024, 1024],
  },
  "Qwen-Image" => {
    label: "Qwen Image",
    aliases: ["qwen-image", "qwen_image"],
    description: "Qwen Image — best-in-class text rendering (Chinese/English), Qwen2.5-VL encoder",
    default_resolution: [1024, 1024],
  },
  "Wan" => {
    label: "Wan Video",
    aliases: ["Wan2.1", "Wan2.2", "wan-t2v", "wan-i2v"],
    description: "Video generation — Wan 2.1/2.2 via sd.cpp",
    default_resolution: [384, 672],
  },
}.freeze

# Canonical family names for quick lookup from aliases
MODEL_FAMILY_LOOKUP = MODEL_FAMILIES.each_with_object({}) do |(family, info), h|
  h[family.downcase] = family
  info[:aliases].each { |a| h[a.downcase] = family }
end.freeze

# Best settings per model type — applied when user confirms after selecting a model
MODEL_BEST_SETTINGS = {
  "FLUX2"  => { "steps" => 4, "cfg_scale" => 1.0, "width" => 1024, "height" => 1024, "sampler" => "euler", "scheduler" => "simple" },
  "Chroma" => { "steps" => 26, "cfg_scale" => 4.0, "width" => 1024, "height" => 1024, "sampler" => "euler", "scheduler" => "simple" },
  "Z-Image" => { "steps" => 20, "cfg_scale" => 5.0, "width" => 1024, "height" => 1024, "sampler" => "euler", "scheduler" => "simple" },
  "Qwen-Image" => { "steps" => 20, "cfg_scale" => 2.5, "width" => 1024, "height" => 1024, "sampler" => "euler", "scheduler" => "simple" },
  "FLUX"   => { "steps" => 8, "cfg_scale" => 1.0, "width" => 1024, "height" => 1024, "sampler" => "euler", "scheduler" => "simple" },
  "SDXL"   => { "steps" => 25, "cfg_scale" => 7.0, "width" => 1024, "height" => 1024, "sampler" => "dpm++2m", "scheduler" => "karras" },
  "SD 1.x" => { "steps" => 20, "cfg_scale" => 7.0, "width" => 512, "height" => 512, "sampler" => "euler_a", "scheduler" => "karras" },
  "SD 2.x" => { "steps" => 25, "cfg_scale" => 7.0, "width" => 768, "height" => 768, "sampler" => "euler_a", "scheduler" => "karras" },
  "SD3"    => { "steps" => 28, "cfg_scale" => 5.0, "width" => 1024, "height" => 1024, "sampler" => "euler", "scheduler" => "simple" },
  "Wan"    => { "steps" => 15, "cfg_scale" => 5.0, "width" => 384, "height" => 672, "sampler" => "euler", "scheduler" => "simple", "video_frames" => 17, "fps" => 8 },
}.freeze

# Recommended img2img settings per model type — higher steps + tuned strength
IMG2IMG_BEST_SETTINGS = {
  "FLUX"   => { "steps" => 28, "cfg_scale" => 1.0, "strength" => 0.75, "guidance" => 7.0, "sampler" => "euler", "scheduler" => "simple" },
  "SDXL"   => { "steps" => 30, "cfg_scale" => 7.0, "strength" => 0.7, "sampler" => "dpm++2m", "scheduler" => "karras" },
  "SD 1.x" => { "steps" => 30, "cfg_scale" => 7.0, "strength" => 0.75, "sampler" => "euler_a", "scheduler" => "karras" },
  "SD 2.x" => { "steps" => 30, "cfg_scale" => 7.0, "strength" => 0.7, "sampler" => "euler_a", "scheduler" => "karras" },
  "SD3"    => { "steps" => 35, "cfg_scale" => 5.0, "strength" => 0.65, "sampler" => "euler", "scheduler" => "simple" },
  "Wan"    => { "steps" => 20, "cfg_scale" => 5.0, "strength" => 0.75, "sampler" => "euler", "scheduler" => "simple" },
}.freeze

# FLUX companion files needed alongside the diffusion model
FLUX_COMPANION_FILES = {
  "clip_l" => {
    filename: "clip_l.safetensors",
    url: "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors",
  },
  "t5xxl" => {
    filename: "t5xxl_fp16.safetensors",
    url: "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors",
  },
  "vae" => {
    filename: "ae.safetensors",
    url: "https://huggingface.co/second-state/FLUX.1-schnell-GGUF/resolve/main/ae.safetensors",
  },
}.freeze

# Qwen-Image companion files — Qwen2.5-VL-7B LLM + VAE, all from public mirrors
QWEN_IMAGE_COMPANION_FILES = {
  "llm" => {
    filename: "Qwen2.5-VL-7B-Instruct.Q5_K_M.gguf",
    url: "https://huggingface.co/mradermacher/Qwen2.5-VL-7B-Instruct-GGUF/resolve/main/Qwen2.5-VL-7B-Instruct.Q5_K_M.gguf",
  },
  "vae" => {
    filename: "qwen_image_vae.safetensors",
    url: "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors",
  },
}.freeze

# Z-Image companion files — reuses FLUX.1 ae.safetensors and FLUX.2 Qwen3-4B GGUF.
# If either is already downloaded for another architecture, these are deduplicated.
Z_IMAGE_COMPANION_FILES = {
  "llm" => {
    filename: "Qwen3-4B-Q4_K_M.gguf",
    url: "https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf",
  },
  "vae" => {
    filename: "ae.safetensors",
    url: "https://huggingface.co/second-state/FLUX.1-schnell-GGUF/resolve/main/ae.safetensors",
  },
}.freeze

# FLUX.2 companion files — variant depends on diffusion model size
# 4B model pairs with Qwen3-4B, 9B model pairs with Qwen3-8B. VAE is shared.
FLUX2_COMPANION_FILES = {
  # FLUX.2 Dev uses Mistral-Small-3.2-24B as its text encoder (not Qwen3).
  :_dev => {
    "llm" => {
      filename: "Mistral-Small-3.2-24B-Instruct-2506-Q3_K_M.gguf",
      url: "https://huggingface.co/unsloth/Mistral-Small-3.2-24B-Instruct-2506-GGUF/resolve/main/Mistral-Small-3.2-24B-Instruct-2506-Q3_K_M.gguf",
    },
    "vae" => {
      filename: "flux2-vae.safetensors",
      url: "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/vae/flux2-vae.safetensors",
    },
  },
  :_9b => {
    "llm" => {
      filename: "Qwen3-8B-Q4_K_M.gguf",
      url: "https://huggingface.co/unsloth/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf",
    },
    "vae" => {
      filename: "flux2-vae.safetensors",
      url: "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/vae/flux2-vae.safetensors",
    },
  },
  :_4b => {
    "llm" => {
      filename: "Qwen3-4B-Q4_K_M.gguf",
      url: "https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf",
    },
    "vae" => {
      filename: "flux2-vae.safetensors",
      url: "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/vae/flux2-vae.safetensors",
    },
  },
}.freeze

# Wan companion files needed alongside the diffusion model
WAN_COMPANION_FILES = {
  "t5xxl" => {
    filename: "umt5_xxl_fp8_e4m3fn_scaled.safetensors",
    url: "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
  },
  "clip_vision" => {
    filename: "clip_vision_h.safetensors",
    url: "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors",
  },
  "vae" => {
    filename: "wan_2.1_vae.safetensors",
    url: "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors",
  },
}.freeze

# Curated list of recommended models for new users
PRELOADED_MODELS = [
  {
    name: "Stable Diffusion 1.5 (Q8)",
    repo: "second-state/stable-diffusion-v1-5-GGUF",
    file: "stable-diffusion-v1-5-pruned-emaonly-Q8_0.gguf",
    size: 1_640_000_000,
    type: "SD 1.5",
    model_family: "SD 1.x",
    desc: "Classic SD 1.5 — fast, low VRAM, great for learning",
  },
  {
    name: "Stable Diffusion 3.5 Medium (Q5)",
    repo: "second-state/stable-diffusion-3.5-medium-GGUF",
    file: "sd3.5_medium-Q5_0.gguf",
    size: 2_200_000_000,
    type: "SD 3.5",
    model_family: "SD3",
    desc: "Newest SD architecture — excellent quality/speed balance",
  },
  {
    name: "SDXL Turbo (Q4)",
    repo: "gpustack/stable-diffusion-xl-1.0-turbo-GGUF",
    file: "stable-diffusion-xl-1.0-turbo-Q4_0.gguf",
    size: 3_670_000_000,
    type: "SDXL",
    model_family: "SDXL",
    desc: "Fast SDXL variant — 1-4 steps, real-time generation",
  },
  {
    name: "Realistic Vision v6 (Q8) — photorealistic",
    repo: "second-state/Realistic_Vision_V6.0_B1-GGUF",
    file: "realisticVisionV60B1_v51HyperVAE-Q8_0.gguf",
    size: 1_765_000_000,
    type: "SD 1.5",
    model_family: "SD 1.x",
    desc: "Best photorealistic SD 1.5 — great for face edits with ControlNet/inpainting",
  },
  {
    name: "DreamShaper v7 LCM (F16)",
    repo: "Steward/lcm-dreamshaper-v7-gguf",
    file: "LCM_Dreamshaper_v7-f16.gguf",
    size: 1_990_000_000,
    type: "SD 1.5",
    model_family: "SD 1.x",
    desc: "DreamShaper with LCM — 4-8 steps, artistic style",
  },
  {
    name: "FLUX.1 Schnell (Q4)",
    repo: "second-state/FLUX.1-schnell-GGUF",
    file: "flux1-schnell-Q4_0.gguf",
    size: 6_876_948_608,
    type: "FLUX",
    model_family: "FLUX",
    desc: "State-of-the-art FLUX — needs companion files (auto-downloaded)",
  },
  {
    name: "Wan 2.1 T2V 1.3B (Q5)",
    repo: "samuelchristlie/Wan2.1-T2V-1.3B-GGUF",
    file: "Wan2.1-T2V-1.3B-Q5_K_M.gguf",
    size: 1_087_410_400,
    type: "Wan",
    model_family: "Wan",
    desc: "Lightweight Wan video — fast text-to-video generation",
  },
].freeze

# Curated list of recommended LoRAs for new users
# Each LoRA includes rich metadata for compatibility filtering and TUI cards
RECOMMENDED_LORAS = [
  {
    name: "Detail Tweaker",
    repo: "jbilcke-hf/sd-lora-detail-tweaker",
    file: "detail_tweaker.safetensors",
    size: 36_000_000,
    model_family: "SD 1.x",
    lora_type: :style,
    desc: "Enhance or reduce fine details — works with any SD 1.5 model",
    use_for: "Adding crisp detail or softening textures",
    avoid: "Already highly detailed prompts at high weight",
    recommended_weight: { min: 0.4, max: 1.0, default: 0.7 },
    tags: %w[detail enhance texture sharpness],
    example_prompt: "a detailed portrait, intricate clothing <lora:detail_tweaker:0.7>",
  },
  {
    name: "LCM LoRA (SD 1.5)",
    repo: "latent-consistency/lcm-lora-sdv1-5",
    file: "pytorch_lora_weights.safetensors",
    size: 67_000_000,
    model_family: "SD 1.x",
    lora_type: :task,
    desc: "Latent Consistency — generate in 4-8 steps instead of 20+",
    use_for: "Speed — dramatically fewer steps needed",
    avoid: "High step counts (defeats the purpose)",
    recommended_weight: { min: 0.8, max: 1.0, default: 1.0 },
    tags: %w[speed lcm fast consistency],
    example_prompt: "a cat sitting on a windowsill, 4 steps",
  },
  {
    name: "LCM LoRA (SDXL)",
    repo: "latent-consistency/lcm-lora-sdxl",
    file: "pytorch_lora_weights.safetensors",
    size: 394_000_000,
    model_family: "SDXL",
    lora_type: :task,
    desc: "Latent Consistency for SDXL — fast generation, fewer steps",
    use_for: "Speed — 4-8 steps for SDXL quality",
    avoid: "High step counts",
    recommended_weight: { min: 0.8, max: 1.0, default: 1.0 },
    tags: %w[speed lcm fast sdxl],
    example_prompt: "a landscape at sunset, golden hour, 4 steps",
  },
  {
    name: "Pixel Art (SDXL)",
    repo: "nerijs/pixel-art-xl",
    file: "pixel-art-xl.safetensors",
    size: 44_000_000,
    model_family: "SDXL",
    lora_type: :style,
    desc: "Generate pixel art style images",
    use_for: "Retro / pixel art aesthetic",
    avoid: "Photorealistic prompts",
    recommended_weight: { min: 0.6, max: 1.0, default: 0.8 },
    tags: %w[pixel retro game art style],
    example_prompt: "a fantasy castle, pixel art style <lora:pixel-art-xl:0.8>",
  },
  {
    name: "Papercut (SD 1.5)",
    repo: "Norod78/sd15-papercut-lora",
    file: "papercut.safetensors",
    size: 36_000_000,
    model_family: "SD 1.x",
    lora_type: :style,
    desc: "Paper cutout art style — use 'papercut' in prompt",
    use_for: "Whimsical paper craft aesthetic",
    avoid: "Realistic or photographic prompts",
    recommended_weight: { min: 0.5, max: 0.9, default: 0.7 },
    tags: %w[papercut craft style artistic whimsical],
    example_prompt: "papercut a cute fox in a forest",
  },
].freeze

# Curated list of recommended ControlNet models (.pth checkpoint format for sd.cpp)
RECOMMENDED_CONTROLNETS = [
  {
    name: "Canny Edge (SD 1.5)",
    repo: "lllyasviel/ControlNet-v1-1",
    file: "control_v11p_sd15_canny.pth",
    size: 1_445_000_000,
    model_family: "SD 1.x",
    control_type: :canny,
    desc: "Preserves edges and structure — best for face/pose preservation",
    use_canny: true,
  },
  {
    name: "Depth (SD 1.5)",
    repo: "lllyasviel/ControlNet-v1-1",
    file: "control_v11f1p_sd15_depth.pth",
    size: 1_445_000_000,
    model_family: "SD 1.x",
    control_type: :depth,
    desc: "Preserves spatial depth — good for scenes and landscapes",
    use_canny: false,
  },
  {
    name: "OpenPose (SD 1.5)",
    repo: "lllyasviel/ControlNet-v1-1",
    file: "control_v11p_sd15_openpose.pth",
    size: 1_445_000_000,
    model_family: "SD 1.x",
    control_type: :openpose,
    desc: "Preserves body pose — restyle people while keeping their pose",
    use_canny: false,
  },
].freeze

# Starter packs — curated download bundles for first-time users
STARTER_PACKS = [
  {
    name: "Quick Start",
    desc: "Just SD 1.5 — small, fast, great for learning",
    items: [
      { type: :model, repo: "second-state/stable-diffusion-v1-5-GGUF", file: "stable-diffusion-v1-5-pruned-emaonly-Q8_0.gguf", size: 1_640_000_000 },
    ],
  },
  {
    name: "Creative Studio",
    desc: "SD 1.5 + DreamShaper + Detail Tweaker LoRA — versatile toolkit",
    items: [
      { type: :model, repo: "second-state/stable-diffusion-v1-5-GGUF", file: "stable-diffusion-v1-5-pruned-emaonly-Q8_0.gguf", size: 1_640_000_000 },
      { type: :model, repo: "Steward/lcm-dreamshaper-v7-gguf", file: "LCM_Dreamshaper_v7-f16.gguf", size: 1_990_000_000 },
      { type: :lora, repo: "jbilcke-hf/sd-lora-detail-tweaker", file: "detail_tweaker.safetensors", size: 36_000_000 },
    ],
  },
  {
    name: "Photorealistic + Face Editing",
    desc: "Realistic Vision + ControlNet Canny — best for photo edits and inpainting",
    items: [
      { type: :model, repo: "second-state/Realistic_Vision_V6.0_B1-GGUF", file: "realisticVisionV60B1_v51HyperVAE-Q8_0.gguf", size: 1_765_000_000 },
      { type: :controlnet, repo: "lllyasviel/ControlNet-v1-1", file: "control_v11p_sd15_canny.pth", size: 1_445_000_000 },
    ],
  },
  {
    name: "FLUX (state of the art)",
    desc: "FLUX Schnell — best image quality, needs companion files (auto-downloaded on first use)",
    items: [
      { type: :model, repo: "second-state/FLUX.1-schnell-GGUF", file: "flux1-schnell-Q4_0.gguf", size: 6_876_948_608 },
    ],
  },
  {
    name: "Video (Wan 2.1)",
    desc: "Wan 2.1 T2V — text-to-video generation, needs companion files (auto-downloaded)",
    items: [
      { type: :model, repo: "samuelchristlie/Wan2.1-T2V-1.3B-GGUF", file: "Wan2.1-T2V-1.3B-Q5_K_M.gguf", size: 1_087_410_400 },
    ],
  },
  {
    name: "Full Studio",
    desc: "All of the above — SD 1.5, DreamShaper, Realistic Vision, FLUX, ControlNet, LoRAs",
    items: :all,
  },
].freeze

# LoRA type labels for display
LORA_TYPE_LABELS = {
  style: "Style",
  character: "Character",
  task: "Task",
  concept: "Concept",
  pose: "Pose",
}.freeze

FOCUS_PROMPT   = 0
FOCUS_NEGATIVE = 1
FOCUS_PARAMS   = 2
FOCUS_COUNT    = 3
