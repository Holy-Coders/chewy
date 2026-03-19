# frozen_string_literal: true

CHEWY_VERSION = File.read(File.join(CHEWY_ROOT, "VERSION")).strip rescue "0.0.0"
CHEWY_REPO = "Holy-Coders/chewy"

HF_API_BASE = "https://huggingface.co/api"
HF_DOWNLOAD_BASE = "https://huggingface.co"
CIVITAI_API_BASE = "https://civitai.com/api/v1"
MODEL_EXTENSIONS = %w[.gguf .safetensors .ckpt].freeze
DOWNLOAD_SOURCES = [:huggingface, :civitai].freeze

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
  # --- txt2img (SD) ---
  "Quick Draft" => { "steps" => 10, "cfg_scale" => 7.0, "width" => 512, "height" => 512, "sampler" => "euler", "scheduler" => "ays", "model_type" => "sd" },
  "Balanced" => { "steps" => 20, "cfg_scale" => 7.0, "width" => 512, "height" => 512, "sampler" => "euler_a", "scheduler" => "karras", "model_type" => "sd" },
  "High Quality" => { "steps" => 30, "cfg_scale" => 7.0, "width" => 768, "height" => 768, "sampler" => "dpm++2m", "scheduler" => "karras", "model_type" => "sd" },
  "Max Quality" => { "steps" => 50, "cfg_scale" => 7.5, "width" => 1024, "height" => 1024, "sampler" => "dpm++2m", "scheduler" => "karras", "model_type" => "sdxl" },
  # --- Aspect ratios ---
  "Portrait" => { "steps" => 25, "cfg_scale" => 7.0, "width" => 512, "height" => 768, "sampler" => "euler_a", "scheduler" => "karras", "model_type" => "sd" },
  "Landscape" => { "steps" => 25, "cfg_scale" => 7.0, "width" => 768, "height" => 512, "sampler" => "euler_a", "scheduler" => "karras", "model_type" => "sd" },
  "Widescreen (16:9)" => { "steps" => 25, "cfg_scale" => 7.0, "width" => 896, "height" => 512, "sampler" => "dpm++2m", "scheduler" => "karras" },
  "Square HD" => { "steps" => 25, "cfg_scale" => 7.0, "width" => 1024, "height" => 1024, "sampler" => "dpm++2m", "scheduler" => "karras", "model_type" => "sdxl" },
  # --- img2img ---
  "Image Edit - Quick" => { "steps" => 20, "cfg_scale" => 7.0, "strength" => 0.5, "sampler" => "euler_a", "scheduler" => "karras" },
  "Image Edit - High Quality" => { "steps" => 35, "cfg_scale" => 7.0, "strength" => 0.65, "sampler" => "dpm++2m", "scheduler" => "karras" },
  "Image Edit - Creative" => { "steps" => 30, "cfg_scale" => 8.0, "strength" => 0.85, "sampler" => "euler_a", "scheduler" => "karras" },
  "Image Edit - Subtle" => { "steps" => 25, "cfg_scale" => 7.0, "strength" => 0.3, "sampler" => "dpm++2m", "scheduler" => "karras" },
  # --- FLUX ---
  "FLUX - Quick" => { "steps" => 4, "cfg_scale" => 1.0, "width" => 512, "height" => 512, "sampler" => "euler", "scheduler" => "simple", "model_type" => "flux" },
  "FLUX - Balanced" => { "steps" => 8, "cfg_scale" => 1.0, "width" => 1024, "height" => 1024, "sampler" => "euler", "scheduler" => "simple", "model_type" => "flux" },
  "FLUX - High Quality" => { "steps" => 20, "cfg_scale" => 1.0, "width" => 1024, "height" => 1024, "sampler" => "euler", "scheduler" => "simple", "model_type" => "flux" },
  # --- Styles ---
  "Photorealistic" => { "steps" => 35, "cfg_scale" => 5.0, "width" => 768, "height" => 768, "sampler" => "dpm++2m", "scheduler" => "karras" },
  "Artistic / Painterly" => { "steps" => 30, "cfg_scale" => 10.0, "width" => 768, "height" => 768, "sampler" => "euler_a", "scheduler" => "karras" },
  "Pixel Art" => { "steps" => 20, "cfg_scale" => 8.0, "width" => 512, "height" => 512, "sampler" => "euler", "scheduler" => "discrete" },
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
}.freeze

# Canonical family names for quick lookup from aliases
MODEL_FAMILY_LOOKUP = MODEL_FAMILIES.each_with_object({}) do |(family, info), h|
  h[family.downcase] = family
  info[:aliases].each { |a| h[a.downcase] = family }
end.freeze

# Best settings per model type — applied when user confirms after selecting a model
MODEL_BEST_SETTINGS = {
  "FLUX"   => { "steps" => 8, "cfg_scale" => 1.0, "width" => 1024, "height" => 1024, "sampler" => "euler", "scheduler" => "simple" },
  "SDXL"   => { "steps" => 25, "cfg_scale" => 7.0, "width" => 1024, "height" => 1024, "sampler" => "dpm++2m", "scheduler" => "karras" },
  "SD 1.x" => { "steps" => 20, "cfg_scale" => 7.0, "width" => 512, "height" => 512, "sampler" => "euler_a", "scheduler" => "karras" },
  "SD 2.x" => { "steps" => 25, "cfg_scale" => 7.0, "width" => 768, "height" => 768, "sampler" => "euler_a", "scheduler" => "karras" },
  "SD3"    => { "steps" => 28, "cfg_scale" => 5.0, "width" => 1024, "height" => 1024, "sampler" => "euler", "scheduler" => "simple" },
}.freeze

# Recommended img2img settings per model type — higher steps + tuned strength
IMG2IMG_BEST_SETTINGS = {
  "FLUX"   => { "steps" => 20, "cfg_scale" => 1.0, "strength" => 0.6, "sampler" => "euler", "scheduler" => "simple" },
  "SDXL"   => { "steps" => 30, "cfg_scale" => 7.0, "strength" => 0.7, "sampler" => "dpm++2m", "scheduler" => "karras" },
  "SD 1.x" => { "steps" => 30, "cfg_scale" => 7.0, "strength" => 0.75, "sampler" => "euler_a", "scheduler" => "karras" },
  "SD 2.x" => { "steps" => 30, "cfg_scale" => 7.0, "strength" => 0.7, "sampler" => "euler_a", "scheduler" => "karras" },
  "SD3"    => { "steps" => 35, "cfg_scale" => 5.0, "strength" => 0.65, "sampler" => "euler", "scheduler" => "simple" },
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
