#!/usr/bin/env ruby
# frozen_string_literal: true

require "bubbletea"
require "lipgloss"
require "bubbles"
require "open3"
require "fileutils"
require "net/http"
require "json"
require "uri"
require "yaml"
require "chunky_png"
require "pty"
require "base64"
require "etc"

# ---------- Constants ----------

CHEWY_VERSION = File.read(File.join(__dir__, "VERSION")).strip rescue "0.0.0"
CHEWY_REPO = "Holy-Coders/chewy"

HF_API_BASE = "https://huggingface.co/api"
HF_DOWNLOAD_BASE = "https://huggingface.co"
MODEL_EXTENSIONS = %w[.gguf .safetensors .ckpt].freeze

# Common macOS app model directories
EXTRA_MODEL_DIRS = [
  File.expand_path("~/.diffusionbee"),
  File.expand_path("~/Library/Containers/com.liuliu.draw-things/Data/Documents/Models"),
].freeze
SAMPLER_OPTIONS = %w[euler euler_a heun dpm2 dpm++2s_a dpm++2m dpm++2mv2 ipndm ipndm_v lcm ddim_trailing tcd res_multistep res_2s].freeze
SCHEDULER_OPTIONS = %w[discrete karras exponential ays gits sgm_uniform simple smoothstep kl_optimal].freeze
CONFIG_DIR = File.expand_path("~/.config/sdtui")
CONFIG_PATH = File.join(CONFIG_DIR, "config.yml")
PRESETS_PATH = File.join(CONFIG_DIR, "presets.yml")

BUILTIN_PRESETS = {
  "fast" => { "steps" => 10, "cfg_scale" => 7.0, "width" => 512, "height" => 512, "sampler" => "euler", "scheduler" => "ays" },
  "quality" => { "steps" => 30, "cfg_scale" => 7.0, "width" => 768, "height" => 768, "sampler" => "dpm++2m", "scheduler" => "karras" },
  "portrait" => { "steps" => 20, "cfg_scale" => 7.0, "width" => 512, "height" => 768, "sampler" => "euler_a", "scheduler" => "karras" },
  "flux-fast" => { "steps" => 4, "cfg_scale" => 1.0, "width" => 512, "height" => 512, "sampler" => "euler", "scheduler" => "simple" },
  "flux-quality" => { "steps" => 8, "cfg_scale" => 1.0, "width" => 1024, "height" => 1024, "sampler" => "euler", "scheduler" => "simple" },
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
    desc: "Classic SD 1.5 — fast, low VRAM, great for learning",
  },
  {
    name: "Stable Diffusion 3.5 Medium (Q5)",
    repo: "second-state/stable-diffusion-3.5-medium-GGUF",
    file: "sd3.5_medium-Q5_0.gguf",
    size: 2_200_000_000,
    type: "SD 3.5",
    desc: "Newest SD architecture — excellent quality/speed balance",
  },
  {
    name: "SDXL Turbo (Q4)",
    repo: "gpustack/stable-diffusion-xl-1.0-turbo-GGUF",
    file: "stable-diffusion-xl-1.0-turbo-Q4_0.gguf",
    size: 3_670_000_000,
    type: "SDXL",
    desc: "Fast SDXL variant — 1-4 steps, real-time generation",
  },
  {
    name: "DreamShaper v7 LCM (F16)",
    repo: "Steward/lcm-dreamshaper-v7-gguf",
    file: "LCM_Dreamshaper_v7-f16.gguf",
    size: 1_990_000_000,
    type: "SD 1.5",
    desc: "DreamShaper with LCM — 4-8 steps, artistic style",
  },
  {
    name: "FLUX.1 Schnell (Q4)",
    repo: "second-state/FLUX.1-schnell-GGUF",
    file: "flux1-schnell-Q4_0.gguf",
    size: 6_876_948_608,
    type: "FLUX",
    desc: "State-of-the-art FLUX — needs companion files (auto-downloaded)",
  },
].freeze

# ---------- Themes ----------

THEMES = {
  "midnight" => {
    "primary" => "#874BFD", "secondary" => "#7B2FFF", "accent" => "#FF75B5",
    "success" => "#50FA7B", "warning" => "#F1FA8C", "error" => "#FF5555",
    "text" => "#E2E2E8", "text_dim" => "#8888A0", "text_muted" => "#5C5C78",
    "surface" => "#1E1E2E", "border_dim" => "#3A3A52", "border_focus" => "#874BFD",
    "bar_text" => "#FFFFFF",
  },
  "dracula" => {
    "primary" => "#BD93F9", "secondary" => "#8B5CF6", "accent" => "#FF79C6",
    "success" => "#50FA7B", "warning" => "#F1FA8C", "error" => "#FF5555",
    "text" => "#F8F8F2", "text_dim" => "#8895C7", "text_muted" => "#606888",
    "surface" => "#282A36", "border_dim" => "#44475A", "border_focus" => "#BD93F9",
    "bar_text" => "#FFFFFF",
  },
  "catppuccin" => {
    "primary" => "#CBA6F7", "secondary" => "#89B4FA", "accent" => "#F5C2E7",
    "success" => "#A6E3A1", "warning" => "#F9E2AF", "error" => "#F38BA8",
    "text" => "#CDD6F4", "text_dim" => "#9399B2", "text_muted" => "#6C7086",
    "surface" => "#1E1E2E", "border_dim" => "#313244", "border_focus" => "#CBA6F7",
    "bar_text" => "#1E1E2E",
  },
  "tokyo night" => {
    "primary" => "#7AA2F7", "secondary" => "#7DCFFF", "accent" => "#BB9AF7",
    "success" => "#9ECE6A", "warning" => "#E0AF68", "error" => "#F7768E",
    "text" => "#C0CAF5", "text_dim" => "#737AA2", "text_muted" => "#545C7E",
    "surface" => "#1A1B26", "border_dim" => "#33364E", "border_focus" => "#7AA2F7",
    "bar_text" => "#1A1B26",
  },
  "gruvbox" => {
    "primary" => "#FE8019", "secondary" => "#D79921", "accent" => "#FB4934",
    "success" => "#B8BB26", "warning" => "#FABD2F", "error" => "#CC241D",
    "text" => "#EBDBB2", "text_dim" => "#A89984", "text_muted" => "#7C6F64",
    "surface" => "#282828", "border_dim" => "#504945", "border_focus" => "#FE8019",
    "bar_text" => "#1D2021",
  },
  "nord" => {
    "primary" => "#88C0D0", "secondary" => "#5E81AC", "accent" => "#B48EAD",
    "success" => "#A3BE8C", "warning" => "#EBCB8B", "error" => "#BF616A",
    "text" => "#ECEFF4", "text_dim" => "#8FBCBB", "text_muted" => "#616E88",
    "surface" => "#2E3440", "border_dim" => "#434C5E", "border_focus" => "#88C0D0",
    "bar_text" => "#2E3440",
  },
  "rose pine" => {
    "primary" => "#C4A7E7", "secondary" => "#31748F", "accent" => "#EBBCBA",
    "success" => "#9CCFD8", "warning" => "#F6C177", "error" => "#EB6F92",
    "text" => "#E0DEF4", "text_dim" => "#908CAA", "text_muted" => "#6E6A86",
    "surface" => "#191724", "border_dim" => "#26233A", "border_focus" => "#C4A7E7",
    "bar_text" => "#191724",
  },
  "solarized" => {
    "primary" => "#268BD2", "secondary" => "#2AA198", "accent" => "#D33682",
    "success" => "#859900", "warning" => "#B58900", "error" => "#DC322F",
    "text" => "#93A1A1", "text_dim" => "#839496", "text_muted" => "#657B83",
    "surface" => "#002B36", "border_dim" => "#073642", "border_focus" => "#268BD2",
    "bar_text" => "#FDF6E3",
  },
  "light" => {
    "primary" => "#6C5CE7", "secondary" => "#0984E3", "accent" => "#E84393",
    "success" => "#00B894", "warning" => "#D4A017", "error" => "#D63031",
    "text" => "#2D3436", "text_dim" => "#636E72", "text_muted" => "#95A5A6",
    "surface" => "#F5F5F5", "border_dim" => "#DFE6E9", "border_focus" => "#6C5CE7",
    "bar_text" => "#FFFFFF",
  },
  "horizon" => {
    "primary" => "#FC4777", "secondary" => "#FF58B1", "accent" => "#FFA27B",
    "success" => "#00CE81", "warning" => "#FFA27B", "error" => "#FC4777",
    "text" => "#16161D", "text_dim" => "#6A5B58", "text_muted" => "#9B8C89",
    "surface" => "#FDF0ED", "border_dim" => "#F0D8D2", "border_focus" => "#FC4777",
    "bar_text" => "#FDF0ED",
  },
}.freeze

THEME_NAMES = THEMES.keys.freeze

# Dynamic theme module — reads from the active theme hash
module Theme
  @current = THEMES["midnight"]

  def self.set(name)
    @current = THEMES[name] || THEMES["midnight"]
  end

  def self.current_name
    THEMES.find { |k, v| v == @current }&.first || "midnight"
  end

  def self.PRIMARY;      @current["primary"]; end
  def self.SECONDARY;    @current["secondary"]; end
  def self.ACCENT;       @current["accent"]; end
  def self.SUCCESS;      @current["success"]; end
  def self.WARNING;      @current["warning"]; end
  def self.ERROR;        @current["error"]; end
  def self.TEXT;         @current["text"]; end
  def self.TEXT_DIM;     @current["text_dim"]; end
  def self.TEXT_MUTED;   @current["text_muted"]; end
  def self.SURFACE;      @current["surface"]; end
  def self.BORDER_DIM;   @current["border_dim"]; end
  def self.BORDER_FOCUS; @current["border_focus"]; end
  def self.BAR_TEXT;     @current["bar_text"]; end

  def self.gradient(c1, c2, steps)
    Lipgloss::ColorBlend.blends(c1, c2, steps, mode: Lipgloss::ColorBlend::HCL)
  rescue
    Array.new(steps) { c1 }
  end

  def self.gradient_text(text, c1, c2)
    chars = text.chars
    return text if chars.empty?
    colors = gradient(c1, c2, [chars.length, 2].max)
    chars.each_with_index.map { |ch, i|
      Lipgloss::Style.new.foreground(colors[[i, colors.length - 1].min]).render(ch)
    }.join
  end
end

FOCUS_PROMPT   = 0
FOCUS_NEGATIVE = 1
FOCUS_PARAMS   = 2
FOCUS_COUNT    = 3

# ---------- Custom Messages ----------

class GenerationDoneMessage < Bubbletea::Message
  attr_reader :output_path, :elapsed, :stderr_output
  def initialize(output_path:, elapsed:, stderr_output: "")
    @output_path = output_path; @elapsed = elapsed; @stderr_output = stderr_output
  end
end

class RevealTickMessage < Bubbletea::Message
  attr_reader :phase
  def initialize(phase:) @phase = phase end
end

class SplashTickMessage < Bubbletea::Message
  attr_reader :phase
  def initialize(phase:) @phase = phase end
end

class GenerationErrorMessage < Bubbletea::Message
  attr_reader :error, :stderr_output
  def initialize(error:, stderr_output: "")
    @error = error; @stderr_output = stderr_output
  end
end

class ReposFetchedMessage < Bubbletea::Message
  attr_reader :repos
  def initialize(repos:) @repos = repos end
end

class ReposFetchErrorMessage < Bubbletea::Message
  attr_reader :error
  def initialize(error:) @error = error end
end

class FilesFetchedMessage < Bubbletea::Message
  attr_reader :files, :repo_id
  def initialize(files:, repo_id:) @files = files; @repo_id = repo_id end
end

class FilesFetchErrorMessage < Bubbletea::Message
  attr_reader :error
  def initialize(error:) @error = error end
end

class ModelDownloadDoneMessage < Bubbletea::Message
  attr_reader :path, :filename
  def initialize(path:, filename:) @path = path; @filename = filename end
end

class ModelDownloadErrorMessage < Bubbletea::Message
  attr_reader :error
  def initialize(error:) @error = error end
end

class CompanionDownloadDoneMessage < Bubbletea::Message
  attr_reader :name
  def initialize(name:) @name = name end
end

class CompanionDownloadErrorMessage < Bubbletea::Message
  attr_reader :name, :error
  def initialize(name:, error:) @name = name; @error = error end
end

class ClipboardPasteMessage < Bubbletea::Message
  attr_reader :path, :error
  def initialize(path: nil, error: nil) @path = path; @error = error end
end

class ModelValidatedMessage < Bubbletea::Message
  attr_reader :path, :model_type, :error
  def initialize(path:, model_type: nil, error: nil) @path = path; @model_type = model_type; @error = error end
end

# ---------- Provider Interface ----------

module Provider
  Capabilities = Struct.new(
    :negative_prompt, :seed, :batch, :img2img, :live_preview,
    :cancel, :model_listing, :lora, :cfg_scale, :sampler,
    :scheduler, :threads, :strength, :width_height,
    keyword_init: true
  ) do
    def initialize(**kwargs)
      defaults = { negative_prompt: false, seed: false, batch: false, img2img: false,
                   live_preview: false, cancel: false, model_listing: false, lora: false,
                   cfg_scale: false, sampler: false, scheduler: false, threads: false,
                   strength: false, width_height: true }
      super(**defaults.merge(kwargs))
    end
  end

  GenerationRequest = Struct.new(
    :prompt, :negative_prompt, :model, :steps, :cfg_scale,
    :width, :height, :seed, :sampler, :scheduler, :batch,
    :init_image, :strength, :threads, :loras, :output_dir,
    :is_flux, :flux_clip_l, :flux_t5xxl, :flux_vae,
    keyword_init: true
  )

  GenerationResult = Struct.new(:paths, :seeds, :elapsed, :error, keyword_init: true)

  # Where provider API keys are stored (not in config YAML)
  KEYS_DIR = File.join(CONFIG_DIR, "keys")

  class Base
    def id; raise NotImplementedError; end
    def display_name; raise NotImplementedError; end
    def provider_type; :local; end
    def capabilities; raise NotImplementedError; end
    def capabilities_for_model(model_id); capabilities; end
    def list_models; []; end
    def generate(request, cancelled: -> { false }, &on_event); raise NotImplementedError; end
    def cancel(handle); end
    def needs_api_key?; false; end
    def api_key_env_var; nil; end
    def api_key_setup_url; nil; end
    def api_key_set?; !needs_api_key?; end

    def resolve_api_key
      return nil unless needs_api_key?
      # Env var takes priority, then stored key file
      ENV[api_key_env_var] || load_stored_key
    end

    def store_api_key(key)
      FileUtils.mkdir_p(Provider::KEYS_DIR)
      path = File.join(Provider::KEYS_DIR, "#{id}.key")
      File.write(path, key)
      File.chmod(0600, path)
    rescue => e
      nil
    end

    private

    def load_stored_key
      path = File.join(Provider::KEYS_DIR, "#{id}.key")
      return nil unless File.exist?(path)
      key = File.read(path).strip
      key.empty? ? nil : key
    rescue
      nil
    end
  end
end

# ---------- Local sd.cpp Provider ----------

class LocalSdCppProvider < Provider::Base
  def initialize(sd_bin:, models_dir:, lora_dir:)
    @sd_bin = sd_bin; @models_dir = models_dir; @lora_dir = lora_dir
  end

  def id; "local_sd_cpp"; end
  def display_name; "Local (sd.cpp)"; end
  def provider_type; :local; end

  def capabilities
    Provider::Capabilities.new(
      negative_prompt: true, seed: true, batch: true, img2img: true,
      live_preview: true, cancel: true, model_listing: true, lora: true,
      cfg_scale: true, sampler: true, scheduler: true, threads: true,
      strength: true, width_height: true
    )
  end

  def generate(request, cancelled: -> { false }, &on_event)
    preview_path = File.join(request.output_dir, ".preview_#{Process.pid}.png")
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    output_path = File.join(request.output_dir, "#{timestamp}.png")

    on_event&.call(:preview_path, preview_path)

    args = build_command(request, output_path, preview_path)

    start_time = Time.now
    pty_r, _pty_w, pid = PTY.spawn(*args)
    on_event&.call(:pid, pid)

    all_output = +""; parsed_seed = nil; sampling_started = false
    buf = +""; status = nil; batch_seeds = []

    loop do
      ready = IO.select([pty_r], nil, nil, 0.25)
      if ready
        begin
          chunk = pty_r.readpartial(4096)
          buf << chunk; all_output << chunk
          parse_output(buf, sampling_started, parsed_seed, on_event) do |new_buf, ss, ps|
            if ps && ps != parsed_seed
              batch_seeds << ps
              on_event&.call(:batch_progress, batch_seeds.length)
            end
            buf = new_buf; sampling_started = ss; parsed_seed = ps
          end
        rescue Errno::EIO, EOFError
          break
        end
      end
      begin
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        if status
          loop do
            chunk = pty_r.readpartial(4096)
            all_output << chunk; buf << chunk
            parse_output(buf, sampling_started, parsed_seed, on_event) do |new_buf, ss, ps|
              if ps && ps != parsed_seed
                batch_seeds << ps
                on_event&.call(:batch_progress, batch_seeds.length)
              end
              buf = new_buf; sampling_started = ss; parsed_seed = ps
            end
          rescue Errno::EIO, EOFError
            break
          end
          break
        end
      rescue Errno::ECHILD
        break
      end
    end

    _, status = Process.wait2(pid) rescue nil unless status
    pty_r.close rescue nil
    on_event&.call(:pid, nil)
    elapsed = (Time.now - start_time).round(1)

    File.delete(preview_path) if File.exist?(preview_path)
    on_event&.call(:preview_path, nil)

    if cancelled.call || status&.signaled?
      cleanup_outputs(output_path, request.batch)
      return Provider::GenerationResult.new(error: "Cancelled")
    end

    if status&.success? || status.nil?
      generated = collect_outputs(output_path, request, batch_seeds, parsed_seed)
      if generated.any?
        Provider::GenerationResult.new(
          paths: generated.map(&:first), seeds: generated.map(&:last), elapsed: elapsed
        )
      else
        Provider::GenerationResult.new(error: diagnose_error(all_output, status, request.model))
      end
    else
      Provider::GenerationResult.new(error: diagnose_error(all_output, status, request.model))
    end
  rescue Errno::ENOENT
    on_event&.call(:pid, nil)
    Provider::GenerationResult.new(error: "Binary '#{@sd_bin}' not found. Set SD_BIN env var.")
  rescue => e
    on_event&.call(:pid, nil)
    Provider::GenerationResult.new(error: e.message)
  end

  def cancel(pid)
    Process.kill("TERM", pid) rescue nil
  end

  private

  def build_command(request, output_path, preview_path)
    args = if request.is_flux
      [@sd_bin, "--diffusion-model", request.model,
       "--clip_l", request.flux_clip_l, "--t5xxl", request.flux_t5xxl, "--vae", request.flux_vae,
       "-p", request.prompt,
       "--steps", request.steps.to_s, "--cfg-scale", request.cfg_scale.to_s,
       "--guidance", "3.5",
       "-W", request.width.to_s, "-H", request.height.to_s,
       "--seed", request.seed.to_s, "--sampling-method", request.sampler,
       "--scheduler", request.scheduler,
       "-t", request.threads.to_s, "--fa", "--vae-tiling", "--clip-on-cpu",
       "--cache-mode", "spectrum",
       "-b", request.batch.to_s,
       "-o", output_path]
    else
      [@sd_bin, "-m", request.model, "-p", request.prompt,
       "--steps", request.steps.to_s, "--cfg-scale", request.cfg_scale.to_s,
       "-W", request.width.to_s, "-H", request.height.to_s,
       "--seed", request.seed.to_s, "--sampling-method", request.sampler,
       "--scheduler", request.scheduler,
       "-t", request.threads.to_s, "--fa", "--vae-tiling", "--clip-on-cpu",
       "--cache-mode", "spectrum",
       "-b", request.batch.to_s,
       "-o", output_path]
    end
    args += ["--preview", "proj", "--preview-path", preview_path, "--preview-interval", "1"]
    args += ["--negative-prompt", request.negative_prompt] unless request.negative_prompt.empty?
    args += ["--lora-model-dir", @lora_dir] if request.loras&.any? && !request.is_flux
    if request.init_image
      args += ["--init-img", request.init_image, "--strength", request.strength.to_s]
    end
    args
  end

  def parse_output(buf, sampling_started, parsed_seed, on_event)
    clean = buf.gsub(/\e\[[0-9;]*[A-Za-z]/, "")
    segments = clean.split(/[\r\n]+/)
    new_buf = clean.end_with?("\r", "\n") ? +"" : (segments.pop || +"")
    segments.each do |seg|
      stripped = seg.strip
      next if stripped.empty?
      if seg =~ /\[INFO\s*\]\s*\S+\s*-\s*(.+)/
        info = $1.strip
        if info =~ /loading model/i
          on_event&.call(:status, "Loading model...")
        elsif info =~ /load .+ using (\w+)/i
          on_event&.call(:status, "Loading (#{$1})...")
        elsif info =~ /Version:\s*(.+)/
          on_event&.call(:status, "Model: #{$1.strip}")
        elsif info =~ /total params memory size\s*=\s*([\d.]+\s*\w+)/
          on_event&.call(:status, "Model loaded (#{$1})")
        elsif info =~ /sampling using (.+) method/i
          on_event&.call(:status, "Sampler: #{$1}")
        elsif info =~ /generating image.*seed\s+(\d+)/i
          parsed_seed = $1.to_i
          sampling_started = true
          on_event&.call(:sampling_start, nil)
          on_event&.call(:status, "Sampling (seed #{$1})...")
        elsif info =~ /sampling completed/i
          on_event&.call(:status, "Decoding latents...")
        elsif info =~ /save result/i
          on_event&.call(:status, "Saving image...")
        end
      end
      if !sampling_started && seg =~ /seed\s+(\d+)/i
        parsed_seed = $1.to_i
        sampling_started = true
        on_event&.call(:sampling_start, nil)
      end
      if sampling_started && seg =~ /(\d+)\s*\/\s*(\d+)\s*-\s*([\d.]+)\s*(s\/it|it\/s)/
        step = $1.to_i; total = $2.to_i
        speed_val = $3.to_f
        sps = $4 == "s/it" ? speed_val : (speed_val > 0 ? 1.0 / speed_val : 0)
        on_event&.call(:progress, { step: step, total: total, secs_per_step: sps })
      end
    end
    yield new_buf, sampling_started, parsed_seed
  end

  def collect_outputs(output_path, request, batch_seeds, parsed_seed)
    generated = []
    if request.batch > 1
      base = output_path.sub(/\.png$/, "")
      request.batch.times do |i|
        f = "#{base}_#{i}.png"
        next unless File.exist?(f) && File.size(f) > 0
        ts = Time.now.strftime("%Y%m%d_%H%M%S_%L") + "_#{i}"
        final = File.join(request.output_dir, "#{ts}.png")
        File.rename(f, final)
        generated << [final, batch_seeds[i] || (request.seed == -1 ? nil : request.seed + i)]
      end
    else
      if File.exist?(output_path) && File.size(output_path) > 0
        generated << [output_path, parsed_seed || request.seed]
      end
    end
    generated
  end

  def cleanup_outputs(output_path, batch_count)
    if batch_count > 1
      batch_count.times { |i| File.delete("#{output_path.sub(/\.png$/, "")}_#{i}.png") rescue nil }
    else
      File.delete(output_path) rescue nil
    end
  end

  def diagnose_error(all_output, status, model)
    exit_code = status&.exitstatus || "unknown"
    last_line = all_output.lines.last&.strip || "unknown"
    if all_output.include?("get sd version from file failed") || all_output.include?("new_sd_ctx_t failed")
      name = File.basename(model)
      "\"#{name}\" is not a supported diffusion model — try a different model"
    elsif all_output.include?("out of memory") || all_output.include?("GGML_ASSERT")
      "Not enough memory for this model — try a smaller/quantized version"
    else
      "Failed (exit #{exit_code}): #{last_line}"
    end
  end
end

# ---------- OpenAI Images Provider ----------

class OpenAIImagesProvider < Provider::Base
  MODELS = [
    { id: "gpt-image-1", name: "GPT Image 1", desc: "Latest OpenAI image model" },
    { id: "dall-e-3", name: "DALL-E 3", desc: "High quality, creative" },
    { id: "dall-e-2", name: "DALL-E 2", desc: "Fast, lower cost" },
  ].freeze

  SIZES = {
    "gpt-image-1" => %w[1024x1024 1024x1536 1536x1024 auto],
    "dall-e-3"    => %w[1024x1024 1024x1792 1792x1024],
    "dall-e-2"    => %w[256x256 512x512 1024x1024],
  }.freeze

  def id; "openai"; end
  def display_name; "OpenAI"; end
  def provider_type; :api; end

  def capabilities
    Provider::Capabilities.new(
      negative_prompt: false, seed: false, batch: true, img2img: false,
      live_preview: false, cancel: false, model_listing: true, lora: false,
      cfg_scale: false, sampler: false, scheduler: false, threads: false,
      strength: false, width_height: true
    )
  end

  def needs_api_key?; true; end
  def api_key_env_var; "OPENAI_API_KEY"; end
  def api_key_setup_url; "platform.openai.com/api-keys"; end
  def api_key_set?; !!resolve_api_key; end

  def list_models; MODELS; end

  def generate(request, cancelled: -> { false }, &on_event)
    api_key = resolve_api_key
    return Provider::GenerationResult.new(error: "OPENAI_API_KEY not set") unless api_key

    on_event&.call(:status, "Sending request to OpenAI...")

    model = request.model || "gpt-image-1"
    size = nearest_size(model, request.width, request.height)
    n = [request.batch || 1, 1].max

    body = { model: model, prompt: request.prompt, n: n, size: size }

    if model == "gpt-image-1"
      body[:quality] = request.steps && request.steps >= 20 ? "high" : "auto"
      body[:output_format] = "png"
    elsif model == "dall-e-3"
      body[:quality] = request.steps && request.steps >= 20 ? "hd" : "standard"
      body[:response_format] = "b64_json"
      body[:n] = 1  # dall-e-3 only supports n=1
    else
      body[:response_format] = "b64_json"
    end

    uri = URI.parse("https://api.openai.com/v1/images/generations")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 30
    http.read_timeout = 300

    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{api_key}"
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    on_event&.call(:status, "Generating with #{model}...")
    start_time = Time.now
    resp = http.request(req)
    elapsed = (Time.now - start_time).round(1)

    unless resp.is_a?(Net::HTTPSuccess)
      error_body = JSON.parse(resp.body) rescue {}
      error_msg = error_body.dig("error", "message") || "HTTP #{resp.code}: #{resp.message}"
      return Provider::GenerationResult.new(error: "OpenAI: #{error_msg}")
    end

    data = JSON.parse(resp.body)
    images = data["data"] || []
    return Provider::GenerationResult.new(error: "No images returned") if images.empty?

    on_event&.call(:status, "Saving images...")
    FileUtils.mkdir_p(request.output_dir)

    paths = []
    images.each_with_index do |img, i|
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
      output_path = File.join(request.output_dir, "#{timestamp}_#{i}.png")

      if img["b64_json"]
        File.binwrite(output_path, Base64.decode64(img["b64_json"]))
        paths << output_path
      elsif img["url"]
        img_uri = URI.parse(img["url"])
        img_http = Net::HTTP.new(img_uri.host, img_uri.port)
        img_http.use_ssl = (img_uri.scheme == "https")
        img_resp = img_http.request(Net::HTTP::Get.new(img_uri))
        if img_resp.is_a?(Net::HTTPSuccess)
          File.binwrite(output_path, img_resp.body)
          paths << output_path
        end
      end
    end

    return Provider::GenerationResult.new(error: "Failed to save images") if paths.empty?

    Provider::GenerationResult.new(paths: paths, seeds: [nil] * paths.length, elapsed: elapsed)
  rescue => e
    Provider::GenerationResult.new(error: "OpenAI: #{e.message}")
  end

  private

  def nearest_size(model, w, h)
    valid = SIZES[model] || SIZES["gpt-image-1"]
    concrete = valid.reject { |s| s == "auto" }
    return valid.first if concrete.empty?

    aspect = w.to_f / h
    concrete.min_by do |s|
      sw, sh = s.split("x").map(&:to_i)
      (aspect - sw.to_f / sh).abs
    end
  end
end

# ---------- Fireworks Provider ----------

class FireworksProvider < Provider::Base
  MODELS = [
    { id: "accounts/fireworks/models/flux-1-schnell-fp8", name: "FLUX.1 Schnell", desc: "Fast, 1-4 steps", type: :flux },
    { id: "accounts/fireworks/models/flux-1-dev-fp8", name: "FLUX.1 Dev", desc: "Quality, 20-30 steps", type: :flux },
    { id: "accounts/fireworks/models/flux-1.1-pro", name: "FLUX 1.1 Pro", desc: "Highest quality", type: :flux },
    { id: "accounts/fireworks/models/stable-diffusion-xl-1024-v1-0", name: "SDXL 1.0", desc: "Stable Diffusion XL", type: :sdxl },
    { id: "accounts/fireworks/models/playground-v2-5-1024px-aesthetic", name: "Playground v2.5", desc: "Aesthetic, 1024px", type: :sdxl },
  ].freeze

  BASE_URL = "https://api.fireworks.ai/inference/v1/image_generation".freeze

  def id; "fireworks"; end
  def display_name; "Fireworks"; end
  def provider_type; :api; end

  def capabilities
    Provider::Capabilities.new(
      negative_prompt: true, seed: true, batch: true, img2img: false,
      live_preview: false, cancel: false, model_listing: true, lora: false,
      cfg_scale: true, sampler: false, scheduler: false, threads: false,
      strength: false, width_height: true
    )
  end

  def capabilities_for_model(model_id)
    model_info = MODELS.find { |m| m[:id] == model_id }
    if model_info&.dig(:type) == :flux
      Provider::Capabilities.new(
        negative_prompt: false, seed: true, batch: true, img2img: false,
        live_preview: false, cancel: false, model_listing: true, lora: false,
        cfg_scale: false, sampler: false, scheduler: false, threads: false,
        strength: false, width_height: true
      )
    else
      capabilities
    end
  end

  def needs_api_key?; true; end
  def api_key_env_var; "FIREWORKS_API_KEY"; end
  def api_key_setup_url; "fireworks.ai/api-keys"; end
  def api_key_set?; !!resolve_api_key; end

  def list_models; MODELS; end

  def generate(request, cancelled: -> { false }, &on_event)
    api_key = resolve_api_key
    return Provider::GenerationResult.new(error: "FIREWORKS_API_KEY not set") unless api_key

    model_id = request.model || MODELS.first[:id]
    model_info = MODELS.find { |m| m[:id] == model_id }
    is_flux = model_info&.dig(:type) == :flux

    on_event&.call(:status, "Sending request to Fireworks...")

    # Round dimensions to multiples of 8
    w = (request.width / 8.0).round * 8
    h = (request.height / 8.0).round * 8
    n = [request.batch || 1, 1].max

    body = {
      prompt: request.prompt,
      width: w, height: h,
      samples: n,
      seed: request.seed && request.seed >= 0 ? request.seed : 0,
      safety_check: false,
      output_format: "png",
    }

    if is_flux
      body[:guidance_scale] = 3.5
      body[:steps] = [request.steps || 4, 1].max
    else
      body[:cfg_scale] = request.cfg_scale || 7.0
      body[:steps] = [request.steps || 20, 1].max
      neg = request.negative_prompt.to_s.strip
      body[:negative_prompt] = neg unless neg.empty?
    end

    uri = URI.parse("#{BASE_URL}/#{model_id}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 30
    http.read_timeout = 300

    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{api_key}"
    req["Content-Type"] = "application/json"
    req["Accept"] = n > 1 ? "application/json" : "image/png"
    req.body = JSON.generate(body)

    model_name = model_info&.dig(:name) || model_id.split("/").last
    on_event&.call(:status, "Generating with #{model_name}...")

    start_time = Time.now
    resp = http.request(req)
    elapsed = (Time.now - start_time).round(1)

    # Fireworks can return image binary directly or JSON with b64
    unless resp.is_a?(Net::HTTPSuccess)
      error_body = JSON.parse(resp.body) rescue {}
      error_msg = error_body["error"] || error_body.dig("error", "message") || "HTTP #{resp.code}: #{resp.message}"
      return Provider::GenerationResult.new(error: "Fireworks: #{error_msg}")
    end

    on_event&.call(:status, "Saving images...")
    FileUtils.mkdir_p(request.output_dir)

    content_type = resp["content-type"].to_s

    paths = []
    if content_type.include?("image/")
      # Binary image response
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
      output_path = File.join(request.output_dir, "#{timestamp}_0.png")
      File.binwrite(output_path, resp.body)
      paths << output_path
    else
      # JSON response with b64_json data array
      data = JSON.parse(resp.body)
      images = data["data"] || (data["b64_json"] ? [data] : [])

      images.each_with_index do |img, i|
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
        output_path = File.join(request.output_dir, "#{timestamp}_#{i}.png")
        b64 = img["b64_json"] || img["base64"]
        if b64
          File.binwrite(output_path, Base64.decode64(b64))
          paths << output_path
        end
      end
    end

    return Provider::GenerationResult.new(error: "Failed to save images") if paths.empty?

    seed_val = request.seed && request.seed >= 0 ? request.seed : nil
    Provider::GenerationResult.new(paths: paths, seeds: [seed_val] * paths.length, elapsed: elapsed)
  rescue => e
    Provider::GenerationResult.new(error: "Fireworks: #{e.message}")
  end
end

# ---------- HuggingFace Inference Provider ----------

class HuggingFaceInferenceProvider < Provider::Base
  MODELS = [
    { id: "black-forest-labs/FLUX.1-schnell", name: "FLUX.1 Schnell", desc: "Fast, 1-4 steps" },
    { id: "black-forest-labs/FLUX.1-dev", name: "FLUX.1 Dev", desc: "High quality FLUX" },
    { id: "stabilityai/stable-diffusion-xl-base-1.0", name: "SDXL 1.0", desc: "Stable Diffusion XL" },
    { id: "stabilityai/stable-diffusion-3.5-large", name: "SD 3.5 Large", desc: "Latest SD architecture" },
    { id: "HiDream-ai/HiDream-I1-Full", name: "HiDream I1", desc: "High detail generation" },
  ].freeze

  BASE_URL = "https://router.huggingface.co/hf-inference/models".freeze

  def id; "huggingface"; end
  def display_name; "HuggingFace"; end
  def provider_type; :api; end

  def capabilities
    Provider::Capabilities.new(
      negative_prompt: true, seed: true, batch: false, img2img: false,
      live_preview: false, cancel: false, model_listing: true, lora: false,
      cfg_scale: true, sampler: false, scheduler: false, threads: false,
      strength: false, width_height: true
    )
  end

  def needs_api_key?; true; end
  def api_key_env_var; "HF_TOKEN"; end
  def api_key_setup_url; "huggingface.co/settings/tokens"; end
  def api_key_set?; !!resolve_api_key; end

  def resolve_api_key
    # Check env vars and standard HF token paths
    ENV["HF_TOKEN"] || ENV["HUGGING_FACE_HUB_TOKEN"] ||
      [File.expand_path("~/.cache/huggingface/token"),
       File.expand_path("~/.huggingface/token")].filter_map { |p|
        File.read(p).strip if File.exist?(p)
      }.first || load_stored_key
  end

  def store_api_key(key)
    # Store in standard HF location so it works for companion downloads too
    dir = File.expand_path("~/.cache/huggingface")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "token")
    File.write(path, key)
    File.chmod(0600, path)
  rescue
    super(key)  # fall back to keys dir
  end

  def list_models; MODELS; end

  def generate(request, cancelled: -> { false }, &on_event)
    api_key = resolve_api_key
    return Provider::GenerationResult.new(error: "HF_TOKEN not set") unless api_key

    model_id = request.model || MODELS.first[:id]
    on_event&.call(:status, "Sending request to HuggingFace...")

    body = { inputs: request.prompt }
    params = {}
    neg = request.negative_prompt.to_s.strip
    params[:negative_prompt] = neg unless neg.empty?
    params[:guidance_scale] = request.cfg_scale if request.cfg_scale
    params[:num_inference_steps] = request.steps if request.steps
    params[:width] = request.width if request.width
    params[:height] = request.height if request.height
    params[:seed] = request.seed if request.seed && request.seed >= 0
    body[:parameters] = params unless params.empty?

    uri = URI.parse("#{BASE_URL}/#{model_id}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 30
    http.read_timeout = 300

    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{api_key}"
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    model_name = MODELS.find { |m| m[:id] == model_id }&.dig(:name) || model_id.split("/").last
    on_event&.call(:status, "Generating with #{model_name}...")

    start_time = Time.now
    resp = http.request(req)
    elapsed = (Time.now - start_time).round(1)

    unless resp.is_a?(Net::HTTPSuccess)
      error_body = JSON.parse(resp.body) rescue {}
      error_msg = error_body["error"] || "HTTP #{resp.code}: #{resp.message}"
      # Model loading hint
      if resp.code == "503"
        error_msg = "Model is loading, try again in a moment"
      end
      return Provider::GenerationResult.new(error: "HuggingFace: #{error_msg}")
    end

    on_event&.call(:status, "Saving image...")
    FileUtils.mkdir_p(request.output_dir)

    content_type = resp["content-type"].to_s
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
    output_path = File.join(request.output_dir, "#{timestamp}_0.png")

    if content_type.include?("image/")
      # Binary image response (standard for inference API)
      File.binwrite(output_path, resp.body)
    else
      # JSON response (might have base64)
      data = JSON.parse(resp.body) rescue nil
      if data.is_a?(Array) && data.first&.dig("blob")
        File.binwrite(output_path, Base64.decode64(data.first["blob"]))
      elsif data.is_a?(Hash) && data["b64_json"]
        File.binwrite(output_path, Base64.decode64(data["b64_json"]))
      else
        return Provider::GenerationResult.new(error: "Unexpected response format")
      end
    end

    seed_val = request.seed && request.seed >= 0 ? request.seed : nil
    Provider::GenerationResult.new(paths: [output_path], seeds: [seed_val], elapsed: elapsed)
  rescue => e
    Provider::GenerationResult.new(error: "HuggingFace: #{e.message}")
  end
end

# ---------- Gemini Provider ----------

class GeminiProvider < Provider::Base
  MODELS = [
    { id: "imagen-3.0-generate-002", name: "Imagen 3", desc: "Google's best image model" },
    { id: "imagen-3.0-fast-generate-001", name: "Imagen 3 Fast", desc: "Faster, lower cost" },
    { id: "gemini-2.0-flash-exp", name: "Gemini 2.0 Flash", desc: "Native Gemini image gen" },
  ].freeze

  def id; "gemini"; end
  def display_name; "Gemini"; end
  def provider_type; :api; end

  def capabilities
    Provider::Capabilities.new(
      negative_prompt: true, seed: false, batch: true, img2img: false,
      live_preview: false, cancel: false, model_listing: true, lora: false,
      cfg_scale: false, sampler: false, scheduler: false, threads: false,
      strength: false, width_height: true
    )
  end

  def needs_api_key?; true; end
  def api_key_env_var; "GEMINI_API_KEY"; end
  def api_key_setup_url; "aistudio.google.com/apikey"; end
  def api_key_set?; !!resolve_api_key; end

  def list_models; MODELS; end

  def generate(request, cancelled: -> { false }, &on_event)
    api_key = resolve_api_key
    return Provider::GenerationResult.new(error: "GEMINI_API_KEY not set") unless api_key

    model_id = request.model || MODELS.first[:id]
    on_event&.call(:status, "Sending request to Gemini...")

    is_imagen = model_id.start_with?("imagen")
    n = [request.batch || 1, 1].max

    if is_imagen
      result = generate_imagen(api_key, model_id, request, n, on_event)
    else
      result = generate_gemini_native(api_key, model_id, request, on_event)
    end
    result
  rescue => e
    Provider::GenerationResult.new(error: "Gemini: #{e.message}")
  end

  private

  def generate_imagen(api_key, model_id, request, n, on_event)
    uri = URI.parse("https://generativelanguage.googleapis.com/v1beta/models/#{model_id}:predict?key=#{api_key}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 30
    http.read_timeout = 300

    body = {
      instances: [{ prompt: request.prompt }],
      parameters: {
        sampleCount: [n, 4].min,
        aspectRatio: nearest_aspect(request.width, request.height),
      },
    }
    neg = request.negative_prompt.to_s.strip
    body[:parameters][:negativePrompt] = neg unless neg.empty?

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    model_name = MODELS.find { |m| m[:id] == model_id }&.dig(:name) || model_id
    on_event&.call(:status, "Generating with #{model_name}...")

    start_time = Time.now
    resp = http.request(req)
    elapsed = (Time.now - start_time).round(1)

    unless resp.is_a?(Net::HTTPSuccess)
      error_body = JSON.parse(resp.body) rescue {}
      error_msg = error_body.dig("error", "message") || "HTTP #{resp.code}: #{resp.message}"
      return Provider::GenerationResult.new(error: "Gemini: #{error_msg}")
    end

    data = JSON.parse(resp.body)
    predictions = data["predictions"] || []
    return Provider::GenerationResult.new(error: "No images returned") if predictions.empty?

    on_event&.call(:status, "Saving images...")
    FileUtils.mkdir_p(request.output_dir)

    paths = []
    predictions.each_with_index do |pred, i|
      b64 = pred["bytesBase64Encoded"]
      next unless b64
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
      output_path = File.join(request.output_dir, "#{timestamp}_#{i}.png")
      File.binwrite(output_path, Base64.decode64(b64))
      paths << output_path
    end

    return Provider::GenerationResult.new(error: "Failed to save images") if paths.empty?
    Provider::GenerationResult.new(paths: paths, seeds: [nil] * paths.length, elapsed: elapsed)
  end

  def generate_gemini_native(api_key, model_id, request, on_event)
    uri = URI.parse("https://generativelanguage.googleapis.com/v1beta/models/#{model_id}:generateContent?key=#{api_key}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 30
    http.read_timeout = 300

    body = {
      contents: [{ parts: [{ text: request.prompt }] }],
      generationConfig: { responseModalities: ["TEXT", "IMAGE"] },
    }

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    model_name = MODELS.find { |m| m[:id] == model_id }&.dig(:name) || model_id
    on_event&.call(:status, "Generating with #{model_name}...")

    start_time = Time.now
    resp = http.request(req)
    elapsed = (Time.now - start_time).round(1)

    unless resp.is_a?(Net::HTTPSuccess)
      error_body = JSON.parse(resp.body) rescue {}
      error_msg = error_body.dig("error", "message") || "HTTP #{resp.code}: #{resp.message}"
      return Provider::GenerationResult.new(error: "Gemini: #{error_msg}")
    end

    data = JSON.parse(resp.body)
    parts = data.dig("candidates", 0, "content", "parts") || []
    image_parts = parts.select { |p| p.dig("inlineData", "mimeType")&.start_with?("image/") }
    return Provider::GenerationResult.new(error: "No images in response") if image_parts.empty?

    on_event&.call(:status, "Saving images...")
    FileUtils.mkdir_p(request.output_dir)

    paths = []
    image_parts.each_with_index do |part, i|
      b64 = part.dig("inlineData", "data")
      next unless b64
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
      output_path = File.join(request.output_dir, "#{timestamp}_#{i}.png")
      File.binwrite(output_path, Base64.decode64(b64))
      paths << output_path
    end

    return Provider::GenerationResult.new(error: "Failed to save images") if paths.empty?
    Provider::GenerationResult.new(paths: paths, seeds: [nil] * paths.length, elapsed: elapsed)
  end

  def nearest_aspect(w, h)
    aspect = w.to_f / h
    aspects = { "1:1" => 1.0, "3:4" => 0.75, "4:3" => 1.333, "9:16" => 0.5625, "16:9" => 1.778 }
    aspects.min_by { |_, v| (aspect - v).abs }.first
  end
end

# ---------- OpenAI-Compatible Provider ----------

class OpenAICompatibleProvider < Provider::Base
  def initialize(config = {})
    @base_url = config["base_url"] || "http://localhost:8080/v1"
    @display = config["name"] || "OpenAI-Compatible"
    @env_var = config["api_key_env"] || "OPENAI_COMPAT_API_KEY"
    @setup_url = config["setup_url"]
    @configured_models = (config["models"] || []).map { |m|
      { id: m["id"] || m, name: m["name"] || m["id"] || m, desc: m["desc"] || "" }
    }
  end

  def id; "openai_compat"; end
  def display_name; @display; end
  def provider_type; :api; end

  def capabilities
    Provider::Capabilities.new(
      negative_prompt: false, seed: false, batch: true, img2img: false,
      live_preview: false, cancel: false, model_listing: true, lora: false,
      cfg_scale: false, sampler: false, scheduler: false, threads: false,
      strength: false, width_height: true
    )
  end

  def needs_api_key?; true; end
  def api_key_env_var; @env_var; end
  def api_key_setup_url; @setup_url; end
  def api_key_set?; !!resolve_api_key; end

  def list_models
    return @configured_models unless @configured_models.empty?
    [{ id: "default", name: "Default", desc: @base_url }]
  end

  def generate(request, cancelled: -> { false }, &on_event)
    api_key = resolve_api_key
    return Provider::GenerationResult.new(error: "#{@env_var} not set") unless api_key

    on_event&.call(:status, "Sending request...")

    model = request.model || list_models.first[:id]
    n = [request.batch || 1, 1].max

    body = { model: model, prompt: request.prompt, n: n, size: "#{request.width}x#{request.height}" }
    body[:response_format] = "b64_json"

    uri = URI.parse("#{@base_url}/images/generations")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 30
    http.read_timeout = 300

    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{api_key}"
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    on_event&.call(:status, "Generating...")
    start_time = Time.now
    resp = http.request(req)
    elapsed = (Time.now - start_time).round(1)

    unless resp.is_a?(Net::HTTPSuccess)
      error_body = JSON.parse(resp.body) rescue {}
      error_msg = error_body.dig("error", "message") || "HTTP #{resp.code}: #{resp.message}"
      return Provider::GenerationResult.new(error: error_msg)
    end

    data = JSON.parse(resp.body)
    images = data["data"] || []
    return Provider::GenerationResult.new(error: "No images returned") if images.empty?

    on_event&.call(:status, "Saving images...")
    FileUtils.mkdir_p(request.output_dir)

    paths = []
    images.each_with_index do |img, i|
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
      output_path = File.join(request.output_dir, "#{timestamp}_#{i}.png")
      if img["b64_json"]
        File.binwrite(output_path, Base64.decode64(img["b64_json"]))
        paths << output_path
      elsif img["url"]
        img_uri = URI.parse(img["url"])
        img_http = Net::HTTP.new(img_uri.host, img_uri.port)
        img_http.use_ssl = (img_uri.scheme == "https")
        img_resp = img_http.request(Net::HTTP::Get.new(img_uri))
        if img_resp.is_a?(Net::HTTPSuccess)
          File.binwrite(output_path, img_resp.body)
          paths << output_path
        end
      end
    end

    return Provider::GenerationResult.new(error: "Failed to save images") if paths.empty?
    Provider::GenerationResult.new(paths: paths, seeds: [nil] * paths.length, elapsed: elapsed)
  rescue => e
    Provider::GenerationResult.new(error: e.message)
  end
end

# ---------- Main App ----------

class Chewy
  include Bubbletea::Model

  def initialize
    @config = load_config
    @first_run = !File.exist?(CONFIG_PATH)
    Theme.set(@config["theme"] || "midnight")
    save_config if @first_run

    @width = 80; @height = 24
    @focus = FOCUS_PROMPT

    # Kitty graphics protocol support (Ghostty, Kitty, WezTerm)
    @kitty_graphics = %w[ghostty kitty WezTerm].any? { |t|
      ENV["TERM_PROGRAM"]&.downcase&.include?(t.downcase) || ENV["TERM"]&.include?(t.downcase)
    }

    # Models
    @models_dir = ENV["CHEWY_MODELS_DIR"] || @config["model_dir"] || File.expand_path("~/models")
    @selected_model_path = nil
    @model_list = nil
    @model_paths = []
    @pinned_models = @config["pinned_models"] || []
    @recent_models = @config["recent_models"] || []
    @incompatible_models = @config["incompatible_models"] || []
    @model_types = @config["model_types"] || {}  # path => "SD 1.x", "SDXL", "Flux", etc.

    # Prompt + Negative
    @prompt_input = Bubbles::TextInput.new
    @prompt_input.placeholder = "Describe your image..."
    @prompt_input.prompt = ""
    @prompt_input.placeholder_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).italic(true)
    @prompt_input.text_style = Lipgloss::Style.new.foreground(Theme.TEXT)
    @prompt_input.focus

    @negative_input = Bubbles::TextInput.new
    @negative_input.placeholder = "Negative prompt (optional)..."
    @negative_input.prompt = ""
    @negative_input.placeholder_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).italic(true)
    @negative_input.text_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)

    # Prompt history
    @prompt_history = []
    @history_index = -1
    @saved_prompt = ""

    # Params
    ds = @config["default_steps"] || 20
    dc = (@config["default_cfg"] || 7.0).to_f
    dw = @config["default_width"] || 512
    dh = @config["default_height"] || 512
    @params = { steps: ds, cfg_scale: dc, width: dw, height: dh, seed: -1, batch: 1, strength: 0.75,
                 threads: @config["default_threads"] || Etc.nprocessors }
    @sampler = @config["default_sampler"] || "euler_a"
    @sampler_index = SAMPLER_OPTIONS.index(@sampler) || 1
    @scheduler = @config["default_scheduler"] || "discrete"
    @scheduler_index = SCHEDULER_OPTIONS.index(@scheduler) || 0
    @param_display_keys = %i[steps cfg_scale width height seed sampler scheduler batch strength threads]
    @param_index = 0
    @editing_param = false
    @param_edit_buffer = ""

    # Generation
    @generating = false
    @gen_pid = nil
    @gen_cancelled = false
    @gen_step = 0
    @gen_total_steps = 0
    @gen_current_batch = 0
    @gen_total_batch = 1
    @last_seed = nil
    @spinner = Bubbles::Spinner.new(spinner: Bubbles::Spinners::PULSE)
    @spinner.style = Lipgloss::Style.new.foreground(Theme.PRIMARY)
    @progress = Bubbles::Progress.new(width: 30, gradient: [Theme.PRIMARY, Theme.ACCENT])
    @last_output_path = nil
    @last_generation_time = nil
    @status_message = @first_run ? "Config created at #{CONFIG_PATH}" : nil
    @error_message = nil

    # Paths
    bundled_sd = File.join(__dir__, "bin", "sd")
    @sd_bin = ENV["SD_BIN"] || @config["sd_bin"] || (File.executable?(bundled_sd) ? bundled_sd : "sd")
    @output_dir = ENV["CHEWY_OUTPUT_DIR"] || @config["output_dir"] || "outputs"
    @lora_dir = ENV["CHEWY_LORA_DIR"] || @config["lora_dir"] || File.expand_path("~/loras")

    # Providers
    @providers = build_providers
    @active_provider_id = @config["active_provider"] || "local_sd_cpp"
    @provider = @providers.find { |p| p.id == @active_provider_id } || @providers.first
    @provider_index = @providers.index(@provider) || 0
    @remote_model_id = @config["remote_model"] || nil
    @remote_model_index = 0

    # Overlay: nil, :models, :download, :history, :lora, :preset, :hf_token, :gallery, :fullscreen_image, :file_picker, :theme, :provider
    @overlay = nil

    # img2img
    @init_image_path = nil
    @file_picker_dir = File.expand_path("~")
    @file_picker_entries = []
    @file_picker_index = 0
    @file_picker_scroll = 0

    # Gallery
    @gallery_images = []
    @gallery_index = 0
    @gallery_thumb_cache = {}

    # Fullscreen image view
    @fullscreen_image_path = nil

    # HF token
    @hf_token_input = Bubbles::TextInput.new
    @hf_token_input.placeholder = "hf_..."
    @hf_token_input.prompt = ""
    @hf_token_input.placeholder_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).italic(true)
    @hf_token_input.text_style = Lipgloss::Style.new.foreground(Theme.TEXT)
    @hf_token_pending_action = nil

    # API key input (for remote providers)
    @api_key_input = Bubbles::TextInput.new
    @api_key_input.placeholder = "sk-..."
    @api_key_input.prompt = ""
    @api_key_input.placeholder_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).italic(true)
    @api_key_input.text_style = Lipgloss::Style.new.foreground(Theme.TEXT)
    @api_key_input.echo_mode = :password

    # Image preview cache
    @preview_cache = nil
    @preview_path = nil

    # Progressive reveal animation
    @reveal_phase = nil  # nil = no animation, 0-4 = progressive phases
    @reveal_path = nil

    # Live generation preview
    @gen_preview_path = nil
    @gen_preview_mtime = nil
    @gen_preview_cache = nil

    # Download browser
    @download_view = :recommended
    @remote_repos = []; @remote_files = []
    @repo_list = nil; @file_list = nil; @recommended_list = nil
    @selected_repo_id = nil
    @fetching = false
    @model_downloading = false
    @download_dest = nil; @download_total = 0; @download_filename = ""
    @download_search_input = Bubbles::TextInput.new
    @download_search_input.placeholder = "Search HuggingFace models..."
    @download_search_input.prompt = ""
    @download_search_input.placeholder_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).italic(true)
    @download_search_input.text_style = Lipgloss::Style.new.foreground(Theme.TEXT)
    @download_search_focused = false

    # Generation history
    @generation_history = []
    @history_list = nil

    # LoRA
    @available_loras = []
    @selected_loras = [] # [{name:, path:, weight:}]
    @lora_index = 0
    @editing_lora_weight = false
    @lora_weight_buffer = ""

    # Presets
    @user_presets = load_presets
    @preset_index = 0
    @naming_preset = false
    @preset_name_buffer = ""
    @confirm_delete_preset = false

    # FLUX companion downloads
    @companion_downloading = false
    @companion_remaining = 0
    @companion_errors = []
    @companion_current_file = ""
    @companion_dest = nil
    @companion_download_size = 0
    @companion_queue = []
    @companion_hf_token = nil

    # Theme picker
    @theme_index = THEME_NAMES.index(Theme.current_name) || 0
    @theme_original = Theme.current_name

    # Splash screen
    @splash = true
    @splash_phase = 0
  end

  # ========== Config ==========

  def load_config
    return {} unless File.exist?(CONFIG_PATH)
    YAML.safe_load(File.read(CONFIG_PATH)) || {}
  rescue
    {}
  end

  def save_config
    FileUtils.mkdir_p(CONFIG_DIR)
    data = {
      "model_dir" => @models_dir || File.expand_path("~/models"),
      "output_dir" => @output_dir || "outputs",
      "sd_bin" => @sd_bin || "sd",
      "lora_dir" => @lora_dir || File.expand_path("~/loras"),
      "default_steps" => @params&.dig(:steps) || 20,
      "default_cfg" => @params&.dig(:cfg_scale) || 7.0,
      "default_width" => @params&.dig(:width) || 512,
      "default_height" => @params&.dig(:height) || 512,
      "default_sampler" => @sampler || "euler_a",
      "default_scheduler" => @scheduler || "discrete",
      "default_threads" => @params&.dig(:threads) || Etc.nprocessors,
      "pinned_models" => @pinned_models || [],
      "recent_models" => @recent_models || [],
      "last_model" => @selected_model_path,
      "incompatible_models" => @incompatible_models || [],
      "model_types" => @model_types || {},
      "theme" => Theme.current_name,
      "active_provider" => @provider&.id || "local_sd_cpp",
      "remote_model" => @remote_model_id,
    }
    @config = data
    File.write(CONFIG_PATH, YAML.dump(data))
  rescue
    nil
  end

  def load_presets
    return {} unless File.exist?(PRESETS_PATH)
    YAML.safe_load(File.read(PRESETS_PATH)) || {}
  rescue
    {}
  end

  def save_presets
    FileUtils.mkdir_p(CONFIG_DIR)
    File.write(PRESETS_PATH, YAML.dump(@user_presets))
  rescue
    nil
  end

  def build_providers
    providers = [
      LocalSdCppProvider.new(sd_bin: @sd_bin, models_dir: @models_dir, lora_dir: @lora_dir),
      OpenAIImagesProvider.new,
      FireworksProvider.new,
      GeminiProvider.new,
      HuggingFaceInferenceProvider.new,
    ]
    # Add user-configured OpenAI-compatible endpoint if present
    if (compat_cfg = @config["openai_compatible"])
      providers << OpenAICompatibleProvider.new(compat_cfg)
    end
    providers
  end

  def update_param_keys
    model_id = @provider.provider_type == :api ? @remote_model_id : nil
    caps = model_id ? @provider.capabilities_for_model(model_id) : @provider.capabilities
    keys = []
    keys << :steps if caps.sampler || caps.cfg_scale
    keys << :cfg_scale if caps.cfg_scale
    keys << :width << :height if caps.width_height
    keys << :seed if caps.seed
    keys << :sampler if caps.sampler
    keys << :scheduler if caps.scheduler
    keys << :batch if caps.batch
    keys << :strength if caps.strength
    keys << :threads if caps.threads
    @param_display_keys = keys
    @param_index = [[@param_index, keys.length - 1].min, 0].max
  end

  # ========== Init ==========

  def init
    scan_models
    scan_loras
    load_generation_history
    _spinner, spinner_cmd = @spinner.init
    splash_cmd = Bubbletea.tick(0.4) { SplashTickMessage.new(phase: 1) }
    [self, Bubbletea.batch(spinner_cmd, splash_cmd)]
  end

  # ========== Update ==========

  def update(message)
    case message
    when Bubbletea::WindowSizeMessage
      @width = message.width; @height = message.height
      resize_components
      [self, nil]
    when Bubbles::Spinner::TickMessage
      @spinner, cmd = @spinner.update(message)
      [self, cmd]
    when Bubbles::Progress::FrameMessage
      @progress, cmd = @progress.update(message)
      [self, cmd]
    when GenerationDoneMessage
      @generating = false; @gen_pid = nil; @gen_start_time = nil
      @last_output_path = message.output_path
      @last_generation_time = message.elapsed
      @preview_cache = nil
      @status_message = nil; @error_message = nil
      load_generation_history
      # Start progressive reveal animation
      @reveal_phase = 0
      @reveal_path = message.output_path
      cmd = Bubbletea.tick(0.05) { RevealTickMessage.new(phase: 1) }
      [self, cmd]
    when RevealTickMessage
      handle_reveal_tick(message)
    when GenerationErrorMessage
      @generating = false; @gen_pid = nil; @gen_start_time = nil
      @error_message = message.error; @status_message = nil
      [self, nil]
    when ReposFetchedMessage
      handle_repos_fetched(message)
    when ReposFetchErrorMessage
      @fetching = false; @error_message = "Fetch failed: #{message.error}"
      [self, nil]
    when FilesFetchedMessage
      handle_files_fetched(message)
    when FilesFetchErrorMessage
      @fetching = false; @error_message = "Fetch failed: #{message.error}"
      [self, nil]
    when ModelDownloadDoneMessage
      handle_download_done(message)
    when ModelDownloadErrorMessage
      @model_downloading = false; @download_dest = nil; @download_filename = ""
      @error_message = "Download failed: #{message.error}"
      [self, nil]
    when CompanionDownloadDoneMessage
      @companion_remaining -= 1
      # Start next companion download (sequential with progress)
      return start_next_companion_download(@companion_queue || [], @companion_hf_token)
    when CompanionDownloadErrorMessage
      @companion_remaining -= 1
      @companion_errors << "#{message.name}: #{message.error}"
      # Continue with next even if one failed
      return start_next_companion_download(@companion_queue || [], @companion_hf_token)
    when ClipboardPasteMessage
      if message.error
        @error_message = message.error
      else
        @init_image_path = message.path
        @status_message = "Pasted image: #{File.basename(message.path)}"
      end
      [self, nil]
    when ModelValidatedMessage
      handle_model_validated(message)
    when SplashTickMessage
      handle_splash_tick(message)
    when Bubbletea::KeyMessage
      return dismiss_splash if @splash
      handle_key(message)
    else
      forward_to_focused(message)
    end
  end

  # ========== View ==========

  def view
    apply_theme_styles

    # Shrink dimensions for padding: 2 chars left/right, 1 line top/bottom
    saved_w = @width; saved_h = @height
    @width = @width - 4
    @height = @height - 2

    content = if @splash
      render_splash
    else
      case @overlay
      when :models   then render_overlay_panel("Models", render_models_content, render_models_status)
      when :download then render_download_view
      when :history  then render_overlay_panel("Generation History", render_history_content, render_history_status)
      when :lora     then render_overlay_panel("LoRA Selection", render_lora_content, render_lora_status)
      when :preset   then render_overlay_panel("Presets", render_preset_content, render_preset_status)
      when :hf_token then render_overlay_panel("HuggingFace Token", render_hf_token_content, render_hf_token_status)
      when :gallery  then render_gallery_view
      when :fullscreen_image then render_fullscreen_image
      when :file_picker then render_overlay_panel("Select Image", render_file_picker_content, render_file_picker_status)
      when :theme then render_overlay_panel("Theme", render_theme_content, render_theme_status)
      when :provider then render_overlay_panel("Provider", render_provider_content, render_provider_status)
      when :api_key then render_overlay_panel("API Key", render_api_key_content, render_api_key_status)
      else render_main_view
      end
    end

    @width = saved_w; @height = saved_h

    # Fill entire terminal with theme surface background, with inner padding
    output = Lipgloss::Style.new.background(Theme.SURFACE).width(@width).height(@height).padding(1, 2).render(content)

    # Every inner style emits \e[0m (SGR reset), which clears background back to
    # the terminal default. Re-apply the surface background after every reset so
    # the theme color persists across all styled text.
    bg_seq = surface_bg_escape
    output.gsub("\e[0m", "\e[0m#{bg_seq}")
  end

  private

  # Refresh all input widget styles from the active theme (needed for live theme switching)
  def apply_theme_styles
    # Cursor: style is used when cursor is visible (rendered with .reverse),
    # text_style is used when cursor blinks off (renders the character underneath)
    cur_style = Lipgloss::Style.new.foreground(Theme.TEXT).background(Theme.SURFACE)
    cur_text_style = Lipgloss::Style.new.foreground(Theme.TEXT)
    placeholder = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).italic(true)
    text_fg = Lipgloss::Style.new.foreground(Theme.TEXT)
    text_dim_fg = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)

    [@prompt_input, @hf_token_input, @download_search_input, @api_key_input].each do |input|
      input.placeholder_style = placeholder
      input.text_style = text_fg
      input.cursor.style = cur_style
      input.cursor.text_style = cur_text_style
    end
    @negative_input.placeholder_style = placeholder
    @negative_input.text_style = text_dim_fg
    @negative_input.cursor.style = cur_style
    @negative_input.cursor.text_style = cur_text_style

    @spinner.style = Lipgloss::Style.new.foreground(Theme.PRIMARY)
    @progress = Bubbles::Progress.new(width: @progress&.instance_variable_get(:@width) || 30, gradient: [Theme.PRIMARY, Theme.ACCENT])
  end

  # ========== Model Scanning ==========

  def scan_models
    Dir.glob(File.join(@models_dir, "**", "*.part")).each { |f| File.delete(f) rescue nil }

    companion_names = FLUX_COMPANION_FILES.values.map { |v| v[:filename] }
    ext_glob = "*.{safetensors,gguf,ckpt}"

    # Scan primary dir + any extra app directories that exist
    dirs = [@models_dir] + EXTRA_MODEL_DIRS.select { |d| File.directory?(d) }
    files = dirs.flat_map { |d| Dir.glob(File.join(d, "**", ext_glob)) }
      .uniq
      .reject { |f| companion_names.include?(File.basename(f)) }
      .reject { |f| File.size(f) < 100_000_000 }        # too small to be a diffusion model

    # Sort: pinned first, recent second, rest alphabetical
    pinned = files.select { |f| @pinned_models.include?(f) }
    recent = files.select { |f| @recent_models.include?(f) && !@pinned_models.include?(f) }
    rest = files - pinned - recent

    sorted = pinned + recent + rest

    @model_paths = sorted

    items = if sorted.empty?
      [{ title: "No models found", description: "Press d to download" }]
    else
      sorted.map do |f|
        name = File.basename(f, File.extname(f))
        ext = File.extname(f).delete(".").upcase
        prefix = @pinned_models.include?(f) ? "* " : "  "
        source = model_source_tag(f)
        type_tag = model_type_tag(f)
        { title: "#{prefix}#{name}", description: "#{ext}#{type_tag}#{source}" }
      end
    end

    @model_list = Bubbles::List.new(items, width: @width - 8, height: [@height - 10, 6].max)
    @model_list.show_title = false
    @model_list.show_status_bar = false
    @model_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    @model_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)

    if sorted.any?
      preferred = if @selected_model_path && sorted.include?(@selected_model_path)
        @selected_model_path
      else
        last = @config["last_model"]
        last if last && sorted.include?(last)
      end

      @selected_model_path = preferred || sorted.first
      @model_list.select(sorted.index(@selected_model_path) || 0)
    end
  end

  def model_type_tag(path)
    # Use cached type from previous validation if available
    if @model_types[path]
      return " | #{@model_types[path]}"
    end
    # Guess from filename
    name = File.basename(path).downcase
    type = if name.include?("flux")
      "FLUX"
    elsif name.include?("sdxl") || name.include?("sd_xl")
      "SDXL"
    elsif name.include?("sd3")
      "SD3"
    elsif name.include?("sd15") || name.include?("sd1.") || name.include?("sd_1") || name.include?("v1-")
      "SD 1.x"
    elsif name.include?("sd2") || name.include?("v2-")
      "SD 2.x"
    end
    type ? " | #{type}" : ""
  end

  def model_source_tag(path)
    if path.include?(".diffusionbee")
      " | DiffusionBee"
    elsif path.include?("draw-things")
      " | Draw Things"
    else
      ""
    end
  end

  def validate_model_cmd(path)
    sd_bin = @sd_bin
    Proc.new do
      # Run sd with 1 step at tiny resolution; kill early once we detect the version line
      args = [sd_bin, "-m", path, "-p", "test", "--steps", "1", "-W", "64", "-H", "64", "-o", "/dev/null"]
      r, _w, pid = PTY.spawn(*args)
      output = +""
      type = nil
      begin
        loop do
          chunk = r.readpartial(4096)
          output << chunk
          # Check for version detection
          if output.include?("Version:")
            type = if output.include?("Version: Flux")
              "FLUX"
            elsif output.include?("Version: SDXL")
              "SDXL"
            elsif output.include?("Version: SD 3")
              "SD3"
            elsif output.include?("Version: SD 2")
              "SD 2.x"
            elsif output.include?("Version: SD 1")
              "SD 1.x"
            end
            Process.kill("TERM", pid) rescue nil
            break
          end
        end
      rescue Errno::EIO, EOFError
        # Process ended before printing a detectable version line.
      end
      r.close rescue nil
      Process.wait(pid) rescue nil

      ModelValidatedMessage.new(path: path, model_type: type)
    rescue => e
      ModelValidatedMessage.new(path: path, error: e.message)
    end
  end

  def handle_model_validated(message)
    if message.model_type
      @model_types[message.path] = message.model_type
      save_config
      scan_models  # refresh list to show detected type
    end
    [self, nil]
  end

  def scan_loras
    return unless File.directory?(@lora_dir)
    pattern = File.join(@lora_dir, "**", "*.safetensors")
    @available_loras = Dir.glob(pattern).map do |f|
      { name: File.basename(f, ".safetensors"), path: f }
    end
  end

  def load_generation_history
    return unless File.directory?(@output_dir)
    pattern = File.join(@output_dir, "*.json")
    files = Dir.glob(pattern).sort.reverse
    @generation_history = files.first(100).filter_map do |f|
      data = JSON.parse(File.read(f))
      data["_sidecar_path"] = f
      data["_image_path"] = f.sub(/\.json$/, ".png")
      data
    rescue
      nil
    end
  end

  # ========== Progressive Reveal ==========

  REVEAL_PHASES = 10 # phases 0..9: very blocky → full resolution
  REVEAL_DELAYS = [0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.10, 0.12, 0.14, 0.0].freeze

  def handle_reveal_tick(message)
    phase = message.phase
    # Ignore stale ticks from cancelled/completed reveals
    if @reveal_phase.nil? || phase >= REVEAL_PHASES || @reveal_path != @last_output_path
      @reveal_phase = nil
      @reveal_path = nil
      @preview_cache = nil
      return [self, nil]
    end

    @reveal_phase = phase
    @preview_cache = nil # force re-render at new resolution
    cmd = Bubbletea.tick(REVEAL_DELAYS[phase]) { RevealTickMessage.new(phase: phase + 1) }
    [self, cmd]
  end

  # ========== Splash Screen ==========

  SPLASH_PHASES = 6 # phases 0..5: very blocky → clear → dismiss
  SPLASH_PIXELATE = [32, 16, 8, 4, 2, nil].freeze
  SPLASH_DELAYS = [0.3, 0.25, 0.2, 0.15, 0.8, 0.0].freeze # linger at full res before dismiss

  def handle_splash_tick(message)
    return [self, nil] unless @splash
    phase = message.phase
    if phase >= SPLASH_PHASES
      return dismiss_splash
    end
    @splash_phase = phase
    cmd = Bubbletea.tick(SPLASH_DELAYS[phase]) { SplashTickMessage.new(phase: phase + 1) }
    [self, cmd]
  end

  def dismiss_splash
    @splash = false
    @splash_phase = nil
    [self, nil]
  end

  def render_splash
    logo_path = File.join(__dir__, "logo.png")
    dim = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
    title_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    center = ->(s) { Lipgloss::Style.new.width(@width).align(:center).render(s) }

    max_logo_h = [(@height * 0.6).to_i, 12].max
    max_logo_w = [(@width * 0.4).to_i, 24].max

    logo_img = if File.exist?(logo_path)
      pixelate = SPLASH_PIXELATE[@splash_phase || 0]
      render_logo_halfblocks(logo_path, max_logo_w, max_logo_h, pixelate: pixelate)
    end

    lines = []
    if logo_img
      centered_logo = center_image(logo_img, @width)
      lines += centered_logo.split("\n")
    end
    lines << ""
    lines << center.call(title_style.render("C H E W Y"))
    lines << center.call(dim.render("v#{CHEWY_VERSION}"))
    lines << ""
    lines << center.call(dim.render("press any key to continue"))

    pad_top = [((@height - lines.length) / 2), 0].max
    (Array.new(pad_top, "") + lines).join("\n")
  end

  # ========== Component Resizing ==========

  def resize_components
    lw = left_panel_width
    @prompt_input.width = lw - 6
    @negative_input.width = lw - 6
    @progress = Bubbles::Progress.new(width: [right_panel_width - 10, 20].max, gradient: [Theme.PRIMARY, Theme.ACCENT])
    @model_list.width = @width - 8 if @model_list
    @model_list.height = [@height - 10, 6].max if @model_list
    @preview_cache = nil # invalidate on resize
    resize_download_lists if @overlay == :download
  end

  def resize_download_lists
    w = @width - 4; h = @height - 9  # account for search bar
    @download_search_input.width = w - 12
    @repo_list&.width = w; @repo_list&.height = h
    @file_list&.width = w; @file_list&.height = h
  end

  def left_panel_width = [(@width * 0.45).to_i, 36].max
  def right_panel_width = @width - left_panel_width

  # ========== Focus ==========

  def cycle_focus(reverse: false)
    case @focus
    when FOCUS_PROMPT then @prompt_input.blur
    when FOCUS_NEGATIVE then @negative_input.blur
    end

    @focus = reverse ? (@focus - 1) % FOCUS_COUNT : (@focus + 1) % FOCUS_COUNT

    case @focus
    when FOCUS_PROMPT then @prompt_input.focus
    when FOCUS_NEGATIVE then @negative_input.focus
    end

    unless @focus == FOCUS_PARAMS
      @editing_param = false; @param_edit_buffer = ""
    end
  end

  # ========== Key Handling ==========

  def handle_key(message)
    return handle_overlay_key(message) if @overlay
    handle_main_key(message)
  end

  def handle_main_key(message)
    key = message.to_s

    # Global shortcuts (work everywhere, including text inputs)
    # Note: ctrl+m=Enter, ctrl+h=Backspace, ctrl+i=Tab are indistinguishable in terminals
    case key
    when "ctrl+c" then return [self, Bubbletea.quit]
    when "ctrl+q" then return [self, Bubbletea.quit]
    when "ctrl+n" then return toggle_overlay(:models)     # n = navigate models
    when "ctrl+d" then return enter_download_mode
    when "ctrl+g" then return toggle_overlay(:history)     # g = generation history
    when "ctrl+l" then return toggle_overlay(:lora)
    when "ctrl+p" then return toggle_overlay(:preset)
    when "ctrl+t" then return toggle_overlay(:theme)
    when "ctrl+a" then return toggle_overlay(:gallery)    # a = album/gallery
    when "ctrl+o", "ctrl+e" then open_image(@last_output_path) if @last_output_path; return [self, nil]
    when "ctrl+f" then show_fullscreen_image(@last_output_path) if @last_output_path; return [self, nil]
    when "ctrl+r" then @params[:seed] = -1; return [self, nil]
    when "ctrl+b" then return open_file_picker                  # b = browse init image
    when "ctrl+v" then return paste_image_from_clipboard        # v = paste image
    when "ctrl+u"
      unless @focus == FOCUS_PROMPT || @focus == FOCUS_NEGATIVE
        @init_image_path = nil; @status_message = "Init image cleared"; return [self, nil]
      end
    when "ctrl+x" then if @generating; @gen_cancelled = true; @provider.cancel(@gen_pid) if @provider.capabilities.cancel && @gen_pid; end; return [self, nil]
    when "ctrl+y" then return toggle_overlay(:provider)
    when "tab"    then cycle_focus; return [self, nil]
    when "shift+tab" then cycle_focus(reverse: true); return [self, nil]
    end

    case @focus
    when FOCUS_PROMPT  then handle_prompt_key(message)
    when FOCUS_NEGATIVE then handle_negative_key(message)
    when FOCUS_PARAMS  then handle_params_key(message)
    else [self, nil]
    end
  end

  def handle_prompt_key(message)
    key = message.to_s
    case key
    when "enter" then return start_generation
    when "up"    then history_prev; return [self, nil]
    when "down"  then history_next; return [self, nil]
    end
    @prompt_input, cmd = @prompt_input.update(message)
    [self, cmd]
  end

  def handle_negative_key(message)
    key = message.to_s
    return start_generation if key == "enter"
    @negative_input, cmd = @negative_input.update(message)
    [self, cmd]
  end

  def handle_params_key(message)
    key = message.to_s
    current_key = @param_display_keys[@param_index]

    if @editing_param
      case key
      when "enter"
        commit_param_edit; return [self, nil]
      when "esc"
        @editing_param = false; @param_edit_buffer = ""; return [self, nil]
      when "backspace"
        @param_edit_buffer = @param_edit_buffer[0...-1]; return [self, nil]
      else
        @param_edit_buffer += key if key.match?(/\A[\d.\-]\z/)
        return [self, nil]
      end
    end

    case key
    when "up", "k"
      @param_index = (@param_index - 1) % @param_display_keys.length
    when "down", "j"
      @param_index = (@param_index + 1) % @param_display_keys.length
    when "enter"
      if current_key == :sampler
        @sampler_index = (@sampler_index + 1) % SAMPLER_OPTIONS.length
        @sampler = SAMPLER_OPTIONS[@sampler_index]
      elsif current_key == :scheduler
        @scheduler_index = (@scheduler_index + 1) % SCHEDULER_OPTIONS.length
        @scheduler = SCHEDULER_OPTIONS[@scheduler_index]
      else
        @editing_param = true
        @param_edit_buffer = param_value(current_key).to_s
      end
    when "left"
      if current_key == :sampler
        @sampler_index = (@sampler_index - 1) % SAMPLER_OPTIONS.length
        @sampler = SAMPLER_OPTIONS[@sampler_index]
      elsif current_key == :scheduler
        @scheduler_index = (@scheduler_index - 1) % SCHEDULER_OPTIONS.length
        @scheduler = SCHEDULER_OPTIONS[@scheduler_index]
      end
    when "right"
      if current_key == :sampler
        @sampler_index = (@sampler_index + 1) % SAMPLER_OPTIONS.length
        @sampler = SAMPLER_OPTIONS[@sampler_index]
      elsif current_key == :scheduler
        @scheduler_index = (@scheduler_index + 1) % SCHEDULER_OPTIONS.length
        @scheduler = SCHEDULER_OPTIONS[@scheduler_index]
      end
    end
    [self, nil]
  end

  def param_value(key)
    case key
    when :sampler then @sampler
    when :scheduler then @scheduler
    else @params[key]
    end
  end

  def commit_param_edit
    key = @param_display_keys[@param_index]
    return if key == :sampler || key == :scheduler

    current = @params[key]
    new_val = current.is_a?(Float) ? @param_edit_buffer.to_f : @param_edit_buffer.to_i

    if key == :seed
      @params[key] = new_val
    elsif key == :batch
      @params[key] = new_val.clamp(1, 9)
    elsif key == :strength
      @params[key] = new_val.to_f.clamp(0.01, 1.0)
    elsif key == :threads
      @params[key] = new_val.clamp(1, Etc.nprocessors)
    elsif new_val > 0
      @params[key] = new_val
    end
    @editing_param = false; @param_edit_buffer = ""
  end

  # ========== Prompt History ==========

  def add_to_prompt_history(text)
    return if text.empty?
    @prompt_history.pop if @prompt_history.last == text
    @prompt_history << text
    @prompt_history.shift if @prompt_history.length > 100
    @history_index = -1
  end

  def history_prev
    return if @prompt_history.empty?
    if @history_index == -1
      @saved_prompt = @prompt_input.value
      @history_index = @prompt_history.length - 1
    elsif @history_index > 0
      @history_index -= 1
    else
      return
    end
    @prompt_input.value = @prompt_history[@history_index]
  end

  def history_next
    return if @history_index == -1
    if @history_index < @prompt_history.length - 1
      @history_index += 1
      @prompt_input.value = @prompt_history[@history_index]
    else
      @history_index = -1
      @prompt_input.value = @saved_prompt
    end
  end

  # ========== Pinned / Recent Models ==========

  def toggle_pin(path)
    if @pinned_models.include?(path)
      @pinned_models.delete(path)
    else
      @pinned_models << path
    end
    save_config
    scan_models
  end

  def add_recent_model(path)
    @recent_models.delete(path)
    @recent_models.unshift(path)
    @recent_models = @recent_models.first(5)
    save_config
  end

  # ========== FLUX Support ==========

  def flux_model?(path)
    return false unless path
    basename = File.basename(path).downcase
    basename.include?("flux")
  end

  def flux_companion_path(key)
    info = FLUX_COMPANION_FILES[key]
    return nil unless info
    File.join(@models_dir, info[:filename])
  end

  def flux_companions_present?
    FLUX_COMPANION_FILES.all? { |key, _| File.exist?(flux_companion_path(key)) }
  end

  def missing_flux_companions
    FLUX_COMPANION_FILES.select { |key, _| !File.exist?(flux_companion_path(key)) }
  end

  HF_TOKEN_PATHS = [
    File.expand_path("~/.cache/huggingface/token"),
    File.expand_path("~/.huggingface/token"),
  ].freeze

  def resolve_hf_token
    ENV["HF_TOKEN"] || ENV["HUGGING_FACE_HUB_TOKEN"] || HF_TOKEN_PATHS.filter_map { |p|
      File.read(p).strip if File.exist?(p)
    }.first
  end

  def save_hf_token(token)
    dir = File.dirname(HF_TOKEN_PATHS.first)
    FileUtils.mkdir_p(dir)
    File.write(HF_TOKEN_PATHS.first, token)
  end

  def download_flux_companions
    missing = missing_flux_companions
    return [self, nil] if missing.empty?

    hf_token = resolve_hf_token
    unless hf_token
      @hf_token_pending_action = :flux_companions
      return open_overlay(:hf_token)
    end

    @companion_downloading = true
    @companion_remaining = missing.size
    @companion_errors = []
    @companion_current_file = ""
    @companion_dest = nil

    # Download sequentially so we can show progress for each file
    queue = missing.to_a  # [[name, info], ...]
    start_next_companion_download(queue, hf_token)
  end

  def start_next_companion_download(queue, hf_token)
    if queue.empty?
      @companion_downloading = false
      @companion_current_file = ""
      @companion_dest = nil
      if @companion_errors.empty?
        @status_message = "FLUX companion files ready"
      else
        @error_message = "Some downloads failed: #{@companion_errors.join(', ')}"
      end
      return [self, nil]
    end

    name, info = queue.first
    remaining = queue[1..]
    dest = File.join(@models_dir, info[:filename])
    part = "#{dest}.part"
    url = info[:url]

    @companion_current_file = info[:filename]
    @companion_dest = part
    @companion_download_size = 0

    cmd = Proc.new do
      # First get file size via HEAD request
      size_out, _ = Open3.capture2("curl", "-sI", "-L", url, "-H", "Authorization: Bearer #{hf_token}")
      content_length = size_out[/content-length:\s*(\d+)/i, 1]&.to_i || 0
      @companion_download_size = content_length

      curl_args = ["curl", "-fL", "-o", part, "-sS",
                   "-C", "-", "--retry", "3", "--retry-delay", "2", "--retry-all-errors",
                   "-H", "Authorization: Bearer #{hf_token}", url]
      _out, err, st = Open3.capture3(*curl_args)
      if st.success?
        File.rename(part, dest)
        CompanionDownloadDoneMessage.new(name: name)
      else
        File.delete(part) if File.exist?(part)
        CompanionDownloadErrorMessage.new(name: name, error: "curl failed: #{err.strip}")
      end
    rescue => e
      File.delete(part) rescue nil
      CompanionDownloadErrorMessage.new(name: name, error: e.message)
    end

    @companion_queue = remaining
    @companion_hf_token = hf_token
    [self, cmd]
  end

  # ========== Generation ==========

  def start_generation
    prompt_text = @prompt_input.value.strip
    negative_text = @negative_input.value.strip

    if prompt_text.empty?
      @error_message = "Prompt cannot be empty"; return [self, nil]
    end

    # Local provider needs a model file; remote providers use @remote_model_id
    if @provider.provider_type == :local
      unless @selected_model_path
        @error_message = "No model selected"; return [self, nil]
      end
      if flux_model?(@selected_model_path) && !flux_companions_present?
        return download_flux_companions
      end
    elsif @provider.needs_api_key? && !@provider.api_key_set?
      return open_overlay(:api_key)
    end

    return [self, nil] if @generating

    @generating = true
    @gen_cancelled = false
    @gen_step = 0; @gen_total_steps = 0; @gen_status = "Starting..."
    @gen_start_time = Time.now; @gen_sampling_start = nil; @gen_secs_per_step = nil
    @reveal_phase = nil; @reveal_path = nil
    @gen_current_batch = 0
    @gen_total_batch = @params[:batch]
    @last_seed = nil
    @error_message = nil; @status_message = nil

    add_to_prompt_history(prompt_text)
    add_recent_model(@selected_model_path) if @selected_model_path

    full_prompt = prompt_text
    if @selected_loras.any? && @provider.capabilities.lora
      tags = @selected_loras.map { |l| "<lora:#{l[:name]}:#{l[:weight]}>" }
      full_prompt = "#{prompt_text} #{tags.join(' ')}"
    end

    FileUtils.mkdir_p(@output_dir)

    # Build provider-agnostic request
    model = if @provider.provider_type == :local
      @selected_model_path
    else
      @remote_model_id || @provider.list_models.first&.dig(:id)
    end
    is_flux = @provider.provider_type == :local && @selected_model_path && flux_model?(@selected_model_path)

    request = Provider::GenerationRequest.new(
      prompt: full_prompt, negative_prompt: negative_text,
      model: model, steps: @params[:steps], cfg_scale: @params[:cfg_scale],
      width: @params[:width], height: @params[:height],
      seed: @params[:seed], sampler: @sampler, scheduler: @scheduler,
      batch: @params[:batch], init_image: @init_image_path,
      strength: @params[:strength], threads: @params[:threads],
      loras: @selected_loras, output_dir: @output_dir,
      is_flux: is_flux,
      flux_clip_l: is_flux ? flux_companion_path("clip_l") : nil,
      flux_t5xxl: is_flux ? flux_companion_path("t5xxl") : nil,
      flux_vae: is_flux ? flux_companion_path("vae") : nil,
    )

    sidecar_base = {
      "prompt" => prompt_text, "negative_prompt" => negative_text,
      "model" => model, "steps" => @params[:steps], "cfg_scale" => @params[:cfg_scale],
      "width" => @params[:width], "height" => @params[:height],
      "sampler" => @sampler, "scheduler" => @scheduler,
      "provider" => @provider.id, "provider_name" => @provider.display_name,
    }
    sidecar_base["model_type"] = is_flux ? "flux" : "sd" if @provider.provider_type == :local
    sidecar_base["init_image"] = @init_image_path if @init_image_path
    sidecar_base["strength"] = @params[:strength] if @init_image_path

    provider = @provider  # capture for thread safety

    cmd = Proc.new do
      total_start = Time.now

      result = provider.generate(request, cancelled: -> { @gen_cancelled }) do |event, data|
        case event
        when :status then @gen_status = data
        when :progress
          @gen_step = data[:step]; @gen_total_steps = data[:total]
          @gen_secs_per_step = data[:secs_per_step]
        when :pid then @gen_pid = data
        when :preview_path
          @gen_preview_path = data
          @gen_preview_mtime = nil; @gen_preview_cache = nil
        when :sampling_start
          @gen_sampling_start = Time.now
          @gen_step = 0; @gen_total_steps = 0
        when :batch_progress then @gen_current_batch = data
        end
      end

      @gen_pid = nil
      @gen_preview_path = nil; @gen_preview_mtime = nil; @gen_preview_cache = nil

      if @gen_cancelled
        @gen_cancelled = false
        GenerationErrorMessage.new(error: "Cancelled", stderr_output: "")
      elsif result.error
        GenerationErrorMessage.new(error: result.error, stderr_output: "")
      elsif result.paths&.any?
        @last_seed = result.seeds&.last
        result.paths.each_with_index do |path, i|
          sidecar_path = path.sub(/\.png$/, ".json")
          unless File.exist?(sidecar_path)
            sidecar = sidecar_base.merge(
              "seed" => result.seeds&.[](i),
              "timestamp" => Time.now.iso8601,
              "generation_time_seconds" => result.elapsed
            )
            File.write(sidecar_path, JSON.pretty_generate(sidecar))
          end
        end
        GenerationDoneMessage.new(
          output_path: result.paths.last,
          elapsed: (Time.now - total_start).round(1),
          stderr_output: ""
        )
      else
        GenerationErrorMessage.new(error: "No images generated", stderr_output: "")
      end
    end

    [self, cmd]
  end

  def open_image(path)
    opener = RUBY_PLATFORM.include?("darwin") ? "open" : "xdg-open"
    spawn(opener, path, [:out, :err] => "/dev/null")
  end

  # ========== Forward Messages ==========

  def forward_to_focused(message)
    # Forward to active overlay inputs first
    if @overlay == :download && @download_search_focused
      @download_search_input, cmd = @download_search_input.update(message)
      return [self, cmd]
    end
    if @overlay == :hf_token
      @hf_token_input, cmd = @hf_token_input.update(message)
      return [self, cmd]
    end
    if @overlay == :api_key
      @api_key_input, cmd = @api_key_input.update(message)
      return [self, cmd]
    end

    case @focus
    when FOCUS_PROMPT
      @prompt_input, cmd = @prompt_input.update(message)
      [self, cmd]
    when FOCUS_NEGATIVE
      @negative_input, cmd = @negative_input.update(message)
      [self, cmd]
    else
      [self, nil]
    end
  end

  # ========== Overlay Management ==========

  def toggle_overlay(name)
    if @overlay == name
      close_overlay
    else
      open_overlay(name)
    end
  end

  def open_overlay(name)
    case @focus
    when FOCUS_PROMPT then @prompt_input.blur
    when FOCUS_NEGATIVE then @negative_input.blur
    end
    @overlay = name
    @error_message = nil

    case name
    when :models then scan_models
    when :history then build_history_list
    when :lora then scan_loras
    when :api_key then @api_key_input.focus; @api_key_input.value = ""
    when :hf_token then @hf_token_input.focus
    when :preset then nil
    when :theme then @theme_index = THEME_NAMES.index(Theme.current_name) || 0; @theme_original = Theme.current_name
    when :provider then @provider_index = @providers.index(@provider) || 0
    when :gallery then build_gallery
    when :file_picker then scan_file_picker_dir
    end
    [self, nil]
  end

  def close_overlay
    @hf_token_input.blur if @overlay == :hf_token
    @api_key_input.blur if @overlay == :api_key
    clear_kitty_images if @kitty_graphics
    @overlay = nil
    @error_message = nil
    @preview_cache = nil # force re-render of main preview
    case @focus
    when FOCUS_PROMPT then @prompt_input.focus
    when FOCUS_NEGATIVE then @negative_input.focus
    end
    [self, nil]
  end

  # ========== Download Browser ==========

  def enter_download_mode
    case @focus
    when FOCUS_PROMPT then @prompt_input.blur
    when FOCUS_NEGATIVE then @negative_input.blur
    end
    @overlay = :download; @download_view = :recommended
    @error_message = nil; @fetching = false
    @download_search_input.value = "gguf"
    @download_search_input.blur
    @download_search_focused = false
    build_recommended_list
    [self, nil]
  end

  def build_recommended_list
    items = PRELOADED_MODELS.map do |m|
      already = File.exist?(File.join(@models_dir, m[:file]))
      status = already ? " (installed)" : ""
      { title: "#{m[:name]}#{status}", description: "#{m[:type]} | #{format_bytes(m[:size])} — #{m[:desc]}" }
    end
    items << { title: "Browse HuggingFace...", description: "Search for more models online" }
    @recommended_list = Bubbles::List.new(items, width: @width - 8, height: [@height - 10, 6].max)
    @recommended_list.show_title = false
    @recommended_list.show_status_bar = false
    @recommended_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    @recommended_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
  end

  def enter_hf_search_mode
    @download_view = :repos
    @error_message = nil; @fetching = true
    @download_search_input.value = "gguf"
    @download_search_input.focus
    @download_search_focused = true
    [self, fetch_repos_cmd("gguf")]
  end

  def exit_download_mode
    @overlay = nil; @download_view = :recommended; @fetching = false
    @repo_list = nil; @file_list = nil; @recommended_list = nil
    @remote_repos = []; @remote_files = []; @selected_repo_id = nil; @error_message = nil
    @download_search_input.blur; @download_search_focused = false
    case @focus
    when FOCUS_PROMPT then @prompt_input.focus
    when FOCUS_NEGATIVE then @negative_input.focus
    end
    [self, nil]
  end

  # Model families that sd.cpp cannot run
  INCOMPATIBLE_HF_PATTERNS = %w[qwen lumina pixart cogview unidiffuser].freeze

  def sdcpp_compatible_repo?(repo)
    id = (repo["id"] || "").downcase
    tags = (repo["tags"] || []).map(&:downcase)
    # Reject known incompatible model families
    return false if INCOMPATIBLE_HF_PATTERNS.any? { |p| id.include?(p) || tags.any? { |t| t.include?(p) } }
    true
  end

  def fetch_repos_cmd(query = "gguf")
    search = URI.encode_www_form_component(query)
    Proc.new do
      uri = URI.parse("#{HF_API_BASE}/models?pipeline_tag=text-to-image&search=#{search}&sort=downloads&direction=-1&limit=50")
      all_repos = JSON.parse(hf_get(uri).body)
      repos = all_repos.select { |r| sdcpp_compatible_repo?(r) }.first(25)
      ReposFetchedMessage.new(repos: repos)
    rescue => e
      ReposFetchErrorMessage.new(error: e.message)
    end
  end

  def handle_repos_fetched(message)
    @fetching = false; @remote_repos = message.repos
    @download_search_input.blur
    @download_search_focused = false
    items = @remote_repos.map do |r|
      { title: r["id"], description: "#{format_number(r["downloads"] || 0)} downloads" }
    end
    items = [{ title: "No models found", description: "Try again later" }] if items.empty?
    @repo_list = Bubbles::List.new(items, width: @width - 4, height: @height - 9)
    @repo_list.title = ""
    @repo_list.show_status_bar = false
    @repo_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    @repo_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    [self, nil]
  end

  # Files that are companion/auxiliary, not standalone diffusion models
  COMPANION_FILE_PATTERNS = %w[clip_l clip_g t5xxl ae. vae. text_encoder taesd].freeze

  def fetch_files_cmd(repo_id)
    @fetching = true; @selected_repo_id = repo_id
    Proc.new do
      uri = URI.parse("#{HF_API_BASE}/models/#{repo_id}/tree/main")
      all = JSON.parse(hf_get(uri).body)
      model_files = all.select { |f|
        next false unless f["type"] == "file"
        next false unless MODEL_EXTENSIONS.any? { |ext| f["path"].end_with?(ext) }
        basename = File.basename(f["path"]).downcase
        # Filter out companion/auxiliary files
        next false if COMPANION_FILE_PATTERNS.any? { |p| basename.start_with?(p) }
        true
      }
      FilesFetchedMessage.new(files: model_files, repo_id: repo_id)
    rescue => e
      FilesFetchErrorMessage.new(error: e.message)
    end
  end

  def handle_files_fetched(message)
    @fetching = false; @download_view = :files; @remote_files = message.files
    items = @remote_files.map { |f| { title: f["path"], description: f["size"] ? format_bytes(f["size"]) : "unknown" } }
    items = [{ title: "No model files found", description: "No .gguf or .safetensors" }] if items.empty?
    @file_list = Bubbles::List.new(items, width: @width - 4, height: @height - 9)
    @file_list.title = ""
    @file_list.show_status_bar = false
    @file_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    @file_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    [self, nil]
  end

  def start_model_download(repo_id, filename, size)
    FileUtils.mkdir_p(@models_dir)
    dest = File.join(@models_dir, filename); part = "#{dest}.part"
    @model_downloading = true; @download_dest = part
    @download_total = size || 0; @download_filename = filename; @error_message = nil
    url = "#{HF_DOWNLOAD_BASE}/#{repo_id}/resolve/main/#{URI.encode_www_form_component(filename)}"
    Proc.new do
      _out, err, st = Open3.capture3("curl", "-fL", "-o", part, "-s",
        "-C", "-", "--retry", "5", "--retry-delay", "3", "--retry-all-errors",
        "--connect-timeout", "30", url)
      if st.success?
        File.rename(part, dest)
        ModelDownloadDoneMessage.new(path: dest, filename: filename)
      else
        # Keep .part file so resume works on next attempt
        ModelDownloadErrorMessage.new(error: "Download failed (exit #{st.exitstatus}). Try again to resume.")
      end
    rescue Errno::ENOENT
      File.delete(part) if File.exist?(part)
      ModelDownloadErrorMessage.new(error: "curl not found")
    rescue => e
      File.delete(part) rescue nil
      ModelDownloadErrorMessage.new(error: e.message)
    end
  end

  def handle_download_done(message)
    @model_downloading = false; @download_dest = nil; @download_filename = ""
    @status_message = "Downloaded #{message.filename}"; @error_message = nil
    scan_models
    @overlay = :models
    [self, nil]
  end

  # ========== Overlay Key Handling ==========

  def handle_overlay_key(message)
    key = message.to_s
    return [self, Bubbletea.quit] if key == "ctrl+c"

    case @overlay
    when :models   then handle_models_panel_key(message)
    when :download then handle_download_key(message)
    when :history  then handle_history_panel_key(message)
    when :lora     then handle_lora_panel_key(message)
    when :preset   then handle_preset_panel_key(message)
    when :theme    then handle_theme_key(message)
    when :provider then handle_provider_key(message)
    when :api_key  then handle_api_key_key(message)
    when :hf_token then handle_hf_token_key(message)
    when :gallery  then handle_gallery_key(message)
    when :fullscreen_image then handle_fullscreen_key(message)
    when :file_picker then handle_file_picker_key(message)
    else [self, nil]
    end
  end

  # -- Model picker keys --

  def handle_models_panel_key(message)
    key = message.to_s
    return close_overlay if key == "esc" || key == "q"
    return [self, nil] unless @model_list

    case key
    when "enter"
      idx = @model_list.selected_index rescue 0
      if @model_paths&.any? && idx < @model_paths.length
        @selected_model_path = @model_paths[idx]
        @preview_cache = nil # invalidate preview when model changes
        save_config
        # Validate model in background if we don't know its type yet
        unless @model_types[@selected_model_path]
          validate_cmd = validate_model_cmd(@selected_model_path)
          close_overlay
          return [self, validate_cmd]
        end
      end
      return close_overlay
    when "f"
      idx = @model_list.selected_index rescue 0
      if @model_paths&.any? && idx < @model_paths.length
        toggle_pin(@model_paths[idx])
      end
      return [self, nil]
    when "d"
      return enter_download_mode
    when "delete", "backspace"
      return delete_selected_model
    end

    @model_list, cmd = @model_list.update(message)
    [self, cmd]
  end

  def delete_selected_model
    idx = @model_list.selected_index rescue 0
    return [self, nil] unless @model_paths&.any? && idx < @model_paths.length

    path = @model_paths[idx]
    return [self, nil] unless File.exist?(path)

    size = File.size(path)
    File.delete(path)
    @selected_model_path = nil if @selected_model_path == path
    @status_message = "Deleted #{File.basename(path)} (#{format_bytes(size)})"
    scan_models
    [self, nil]
  end

  # -- Download keys --

  def handle_download_key(message)
    key = message.to_s
    case key
    when "esc"
      return [self, nil] if @model_downloading
      if @download_search_focused
        @download_search_input.blur
        @download_search_focused = false
        return [self, nil]
      end
      return back_to_repos if @download_view == :files
      return back_to_recommended if @download_view == :repos
      return exit_download_mode
    when "q"
      return [self, nil] if @model_downloading || @download_search_focused
      return back_to_repos if @download_view == :files
      return back_to_recommended if @download_view == :repos
      return exit_download_mode
    when "tab"
      if @download_view == :repos
        @download_search_focused = !@download_search_focused
        @download_search_focused ? @download_search_input.focus : @download_search_input.blur
        return [self, nil]
      end
    end
    return [self, nil] if @fetching || @model_downloading

    if @download_search_focused
      return handle_download_search_key(message)
    end

    case @download_view
    when :recommended then handle_recommended_list_key(message)
    when :repos then handle_repo_list_key(message)
    when :files then handle_file_list_key(message)
    else [self, nil]
    end
  end

  def handle_recommended_list_key(message)
    return [self, nil] unless @recommended_list
    if message.to_s == "enter"
      idx = @recommended_list.selected_index rescue 0
      if idx < PRELOADED_MODELS.length
        m = PRELOADED_MODELS[idx]
        dest = File.join(@models_dir, m[:file])
        if File.exist?(dest)
          @error_message = "#{m[:name]} is already installed"
          return [self, nil]
        end
        return [self, start_model_download(m[:repo], m[:file], m[:size])]
      else
        # "Browse HuggingFace..." option
        return enter_hf_search_mode
      end
    end
    @recommended_list, cmd = @recommended_list.update(message)
    [self, cmd]
  end

  def back_to_recommended
    @download_view = :recommended; @file_list = nil; @repo_list = nil
    @remote_files = []; @remote_repos = []; @selected_repo_id = nil; @error_message = nil
    @download_search_input.blur; @download_search_focused = false
    build_recommended_list
    [self, nil]
  end

  def handle_download_search_key(message)
    key = message.to_s
    if key == "enter"
      query = @download_search_input.value.strip
      return [self, nil] if query.empty?
      @fetching = true
      @download_search_input.blur
      @download_search_focused = false
      return [self, fetch_repos_cmd(query)]
    end
    @download_search_input, cmd = @download_search_input.update(message)
    [self, cmd]
  end

  def back_to_repos
    @download_view = :repos; @file_list = nil; @remote_files = []
    @selected_repo_id = nil; @error_message = nil
    @download_search_focused = false; @download_search_input.blur
    [self, nil]
  end

  def handle_repo_list_key(message)
    return [self, nil] unless @repo_list
    if message.to_s == "enter"
      item = @repo_list.selected_item
      return [self, fetch_files_cmd(item[:title])] if item && item[:title] != "No models found"
      return [self, nil]
    end
    @repo_list, cmd = @repo_list.update(message)
    [self, cmd]
  end

  def handle_file_list_key(message)
    return [self, nil] unless @file_list
    if message.to_s == "enter"
      item = @file_list.selected_item
      if item && item[:title] != "No model files found"
        fd = @remote_files.find { |f| f["path"] == item[:title] }
        return [self, start_model_download(@selected_repo_id, item[:title], fd&.dig("size") || 0)]
      end
      return [self, nil]
    end
    @file_list, cmd = @file_list.update(message)
    [self, cmd]
  end

  # -- History keys --

  def build_history_list
    items = @generation_history.map do |h|
      prompt = (h["prompt"] || "?")[0, 40]
      model = File.basename(h["model"] || "?")
      seed = h["seed"] || "?"
      { title: prompt, description: "#{model} | seed:#{seed} | #{(h["timestamp"] || "?")[0, 19]}" }
    end
    items = [{ title: "No history", description: "Generate an image first" }] if items.empty?
    @history_list = Bubbles::List.new(items, width: @width - 4, height: @height - 6)
    @history_list.title = "Generation History"
    @history_list.show_status_bar = false
    @history_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    @history_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
  end

  def handle_history_panel_key(message)
    key = message.to_s
    return close_overlay if key == "esc" || key == "q"
    return [self, nil] unless @history_list

    if key == "enter" && @generation_history.any?
      idx = @history_list.selected_index rescue 0
      entry = @generation_history[idx]
      load_from_history(entry) if entry
      return close_overlay
    end

    @history_list, cmd = @history_list.update(message)
    [self, cmd]
  end

  def load_from_history(entry)
    @prompt_input.value = entry["prompt"] || ""
    @negative_input.value = entry["negative_prompt"] || ""
    @params[:steps] = entry["steps"] || 20
    @params[:cfg_scale] = (entry["cfg_scale"] || 7.0).to_f
    @params[:width] = entry["width"] || 512
    @params[:height] = entry["height"] || 512
    @params[:seed] = entry["seed"] || -1
    @sampler = entry["sampler"] || "euler_a"
    @sampler_index = SAMPLER_OPTIONS.index(@sampler) || 1
    @scheduler = entry["scheduler"] || "discrete"
    @scheduler_index = SCHEDULER_OPTIONS.index(@scheduler) || 0
    if entry["model"] && File.exist?(entry["model"])
      @selected_model_path = entry["model"]
    end
  end

  # -- Gallery keys --

  def build_gallery
    return unless File.directory?(@output_dir)

    pngs = Dir.glob(File.join(@output_dir, "*.png")).sort.reverse
    @gallery_images = pngs.first(200).map do |png|
      json = png.sub(/\.png$/, ".json")
      meta = File.exist?(json) ? (JSON.parse(File.read(json)) rescue {}) : {}
      { path: png, meta: meta }
    end
    @gallery_index = 0
    @gallery_thumb_cache = {}
  end

  def handle_gallery_key(message)
    key = message.to_s
    return close_overlay if key == "esc" || key == "q"
    return [self, nil] if @gallery_images.empty?

    case key
    when "up", "k"
      @gallery_index = (@gallery_index - 1) % @gallery_images.length
    when "down", "j"
      @gallery_index = (@gallery_index + 1) % @gallery_images.length
    when "left", "h"
      @gallery_index = (@gallery_index - 1) % @gallery_images.length
    when "right", "l"
      @gallery_index = (@gallery_index + 1) % @gallery_images.length
    when "enter", " "
      show_fullscreen_image(@gallery_images[@gallery_index][:path])
      return [self, nil]
    when "ctrl+e", "ctrl+o"
      open_image(@gallery_images[@gallery_index][:path])
    when "delete", "backspace"
      delete_gallery_image
    end
    [self, nil]
  end

  def delete_gallery_image
    return if @gallery_images.empty?

    entry = @gallery_images[@gallery_index]
    File.delete(entry[:path]) if File.exist?(entry[:path])
    json = entry[:path].sub(/\.png$/, ".json")
    File.delete(json) if File.exist?(json)
    @gallery_thumb_cache.delete(entry[:path])
    @gallery_images.delete_at(@gallery_index)
    @gallery_index = [[@gallery_index, @gallery_images.length - 1].min, 0].max
    load_generation_history
  end

  # -- Fullscreen image view --

  def show_fullscreen_image(path)
    return unless path && File.exist?(path)
    @fullscreen_image_path = path
    @fullscreen_return_to = @overlay  # remember where we came from
    clear_kitty_images if @kitty_graphics
    @overlay = :fullscreen_image
  end

  def handle_fullscreen_key(message)
    # Any key exits fullscreen
    clear_kitty_images if @kitty_graphics
    @fullscreen_image_path = nil
    @overlay = @fullscreen_return_to
    @fullscreen_return_to = nil
    @preview_cache = nil
    unless @overlay
      case @focus
      when FOCUS_PROMPT then @prompt_input.focus
      when FOCUS_NEGATIVE then @negative_input.focus
      end
    end
    [self, nil]
  end

  # -- LoRA keys --

  def handle_lora_panel_key(message)
    key = message.to_s
    return close_overlay if (key == "esc" || key == "q") && !@editing_lora_weight

    if @editing_lora_weight
      case key
      when "enter"
        val = @lora_weight_buffer.to_f.clamp(0.0, 2.0)
        sel = @selected_loras.find { |l| l[:path] == @available_loras[@lora_index][:path] }
        sel[:weight] = val if sel
        @editing_lora_weight = false; @lora_weight_buffer = ""
      when "esc"
        @editing_lora_weight = false; @lora_weight_buffer = ""
      when "backspace"
        @lora_weight_buffer = @lora_weight_buffer[0...-1]
      else
        @lora_weight_buffer += key if key.match?(/\A[\d.]\z/)
      end
      return [self, nil]
    end

    case key
    when "up", "k"
      @lora_index = (@lora_index - 1) % [@available_loras.length, 1].max
    when "down", "j"
      @lora_index = (@lora_index + 1) % [@available_loras.length, 1].max
    when "enter", " "
      toggle_lora_selection(@lora_index)
    when "w"
      lora = @available_loras[@lora_index]
      if lora && @selected_loras.any? { |l| l[:path] == lora[:path] }
        sel = @selected_loras.find { |l| l[:path] == lora[:path] }
        @editing_lora_weight = true; @lora_weight_buffer = sel[:weight].to_s
      end
    when "+"
      adjust_lora_weight(@lora_index, 0.1)
    when "-"
      adjust_lora_weight(@lora_index, -0.1)
    end
    [self, nil]
  end

  def toggle_lora_selection(idx)
    return if idx >= @available_loras.length
    lora = @available_loras[idx]
    existing = @selected_loras.find_index { |l| l[:path] == lora[:path] }
    if existing
      @selected_loras.delete_at(existing)
    else
      @selected_loras << { name: lora[:name], path: lora[:path], weight: 1.0 }
    end
  end

  def adjust_lora_weight(idx, delta)
    return if idx >= @available_loras.length
    lora = @available_loras[idx]
    sel = @selected_loras.find { |l| l[:path] == lora[:path] }
    sel[:weight] = (sel[:weight] + delta).round(1).clamp(0.0, 2.0) if sel
  end

  # -- Preset keys --

  def handle_preset_panel_key(message)
    key = message.to_s

    if @naming_preset
      case key
      when "enter"
        save_user_preset(@preset_name_buffer) unless @preset_name_buffer.strip.empty?
        @naming_preset = false; @preset_name_buffer = ""
      when "esc"
        @naming_preset = false; @preset_name_buffer = ""
      when "backspace"
        @preset_name_buffer = @preset_name_buffer[0...-1]
      else
        @preset_name_buffer += key if key.length == 1 && key.match?(/[a-zA-Z0-9_ \-]/)
      end
      return [self, nil]
    end

    if @confirm_delete_preset
      case key
      when "y"
        delete_preset_at(@preset_index)
        @confirm_delete_preset = false
      else
        @confirm_delete_preset = false
      end
      return [self, nil]
    end

    return close_overlay if key == "esc" || key == "q"

    all = all_presets
    case key
    when "up", "k"
      @preset_index = (@preset_index - 1) % [all.length, 1].max
    when "down", "j"
      @preset_index = (@preset_index + 1) % [all.length, 1].max
    when "enter"
      load_preset(all[@preset_index]) if all[@preset_index]
      return close_overlay
    when "s"
      @naming_preset = true; @preset_name_buffer = ""
    when "d"
      p = all[@preset_index]
      @confirm_delete_preset = true if p && !p[:builtin]
    end
    [self, nil]
  end

  def all_presets
    builtin = BUILTIN_PRESETS.map { |n, d| { name: n, data: d, builtin: true } }
    user = @user_presets.map { |n, d| { name: n, data: d, builtin: false } }
    builtin + user
  end

  def load_preset(preset)
    d = preset[:data]
    @params[:steps] = d["steps"] if d["steps"]
    @params[:cfg_scale] = d["cfg_scale"].to_f if d["cfg_scale"]
    @params[:width] = d["width"] if d["width"]
    @params[:height] = d["height"] if d["height"]
    @params[:seed] = d["seed"] if d["seed"]
    @params[:batch] = d["batch"] if d["batch"]
    if d["sampler"]
      @sampler = d["sampler"]
      @sampler_index = SAMPLER_OPTIONS.index(@sampler) || 1
    end
    if d["scheduler"]
      @scheduler = d["scheduler"]
      @scheduler_index = SCHEDULER_OPTIONS.index(@scheduler) || 0
    end
  end

  def save_user_preset(name)
    @user_presets[name] = {
      "steps" => @params[:steps], "cfg_scale" => @params[:cfg_scale],
      "width" => @params[:width], "height" => @params[:height],
      "seed" => @params[:seed], "sampler" => @sampler, "scheduler" => @scheduler,
      "batch" => @params[:batch],
    }
    save_presets
  end

  def delete_preset_at(idx)
    all = all_presets
    p = all[idx]
    return if !p || p[:builtin]
    @user_presets.delete(p[:name])
    save_presets
    @preset_index = [0, @preset_index - 1].max
  end

  # ========== File Picker (img2img) ==========

  IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .webp .bmp].freeze

  def open_file_picker
    case @focus
    when FOCUS_PROMPT then @prompt_input.blur
    when FOCUS_NEGATIVE then @negative_input.blur
    end
    @overlay = :file_picker
    @error_message = nil
    # Start in outputs dir if it exists, otherwise home
    @file_picker_dir = if @init_image_path
      File.dirname(@init_image_path)
    elsif File.directory?(@output_dir)
      File.expand_path(@output_dir)
    else
      File.expand_path("~")
    end
    scan_file_picker_dir
    [self, nil]
  end

  def paste_image_from_clipboard
    @status_message = "Reading clipboard..."
    output_dir = @output_dir
    FileUtils.mkdir_p(output_dir)

    cmd = Proc.new do
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
      dest = File.join(output_dir, ".clipboard_#{timestamp}.png")

      if RUBY_PLATFORM.include?("darwin")
        # macOS: use osascript to extract clipboard image as PNG
        script = <<~APPLESCRIPT
          try
            set imgData to the clipboard as «class PNGf»
            set filePath to POSIX file "#{dest}"
            set fileRef to open for access filePath with write permission
            write imgData to fileRef
            close access fileRef
            return "ok"
          on error errMsg
            return "error:" & errMsg
          end try
        APPLESCRIPT
        result, status = Open3.capture2("osascript", "-e", script)
        result = result.strip

        if result == "ok" && File.exist?(dest) && File.size(dest) > 0
          ClipboardPasteMessage.new(path: dest)
        else
          File.delete(dest) if File.exist?(dest)
          err = result.start_with?("error:") ? result.sub("error:", "") : "No image on clipboard"
          ClipboardPasteMessage.new(error: err)
        end
      else
        # Linux: try xclip
        _, status = Open3.capture2("xclip", "-selection", "clipboard", "-t", "image/png", "-o", out: dest)
        if status.success? && File.exist?(dest) && File.size(dest) > 0
          ClipboardPasteMessage.new(path: dest)
        else
          File.delete(dest) if File.exist?(dest)
          ClipboardPasteMessage.new(error: "No image on clipboard (need xclip)")
        end
      end
    rescue => e
      File.delete(dest) rescue nil if dest
      ClipboardPasteMessage.new(error: e.message)
    end

    [self, cmd]
  end

  def scan_file_picker_dir
    entries = []
    # Parent directory entry
    parent = File.dirname(@file_picker_dir)
    entries << { name: "..", path: parent, type: :dir } unless parent == @file_picker_dir

    begin
      Dir.entries(@file_picker_dir).sort.each do |name|
        next if name == "." || name == ".."
        next if name.start_with?(".")  # skip hidden files
        full = File.join(@file_picker_dir, name)

        if File.directory?(full)
          entries << { name: "#{name}/", path: full, type: :dir }
        elsif IMAGE_EXTENSIONS.include?(File.extname(name).downcase)
          size = File.size(full) rescue 0
          entries << { name: name, path: full, type: :file, size: size }
        end
      end
    rescue Errno::EACCES
      @error_message = "Permission denied: #{@file_picker_dir}"
    end

    @file_picker_entries = entries
    @file_picker_index = 0
    @file_picker_scroll = 0
  end

  def handle_file_picker_key(message)
    key = message.to_s
    return close_overlay if key == "esc" || key == "q"
    return [self, nil] if @file_picker_entries.empty?

    visible_h = @height - 10

    case key
    when "up", "k"
      @file_picker_index = (@file_picker_index - 1) % @file_picker_entries.length
    when "down", "j"
      @file_picker_index = (@file_picker_index + 1) % @file_picker_entries.length
    when "enter"
      entry = @file_picker_entries[@file_picker_index]
      if entry[:type] == :dir
        @file_picker_dir = entry[:path]
        scan_file_picker_dir
      else
        # Select image
        @init_image_path = entry[:path]
        @status_message = "Init image: #{File.basename(entry[:path])}"
        return close_overlay
      end
    when "backspace"
      # Go up one directory
      parent = File.dirname(@file_picker_dir)
      unless parent == @file_picker_dir
        @file_picker_dir = parent
        scan_file_picker_dir
      end
    when "~"
      @file_picker_dir = File.expand_path("~")
      scan_file_picker_dir
    end

    # Keep scroll in view
    if @file_picker_index < @file_picker_scroll
      @file_picker_scroll = @file_picker_index
    elsif @file_picker_index >= @file_picker_scroll + visible_h
      @file_picker_scroll = @file_picker_index - visible_h + 1
    end

    [self, nil]
  end

  def render_file_picker_content
    dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    accent = Lipgloss::Style.new.foreground(Theme.ACCENT)
    dir_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    file_style = Lipgloss::Style.new.foreground(Theme.TEXT)
    selected_style = Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true)

    # Current directory header
    header = dim.render("  ") + accent.render(@file_picker_dir)
    lines = [header, ""]

    if @file_picker_entries.empty?
      lines << dim.render("  No image files found")
      return lines.join("\n")
    end

    # Show init image status
    if @init_image_path
      lines << dim.render("  Current: ") + file_style.render(File.basename(@init_image_path))
      lines << ""
    end

    visible_h = @height - 10
    visible = @file_picker_entries[@file_picker_scroll, visible_h] || []

    visible.each_with_index do |entry, i|
      actual_i = @file_picker_scroll + i
      selected = actual_i == @file_picker_index
      cursor = selected ? selected_style.render("> ") : "  "

      if entry[:type] == :dir
        name = selected ? selected_style.render(entry[:name]) : dir_style.render(entry[:name])
        lines << "#{cursor}#{name}"
      else
        name_str = selected ? selected_style.render(entry[:name]) : file_style.render(entry[:name])
        size_str = dim.render("  #{format_bytes(entry[:size] || 0)}")
        lines << "#{cursor}#{name_str}#{size_str}"
      end
    end

    if @file_picker_entries.length > visible_h
      lines << ""
      lines << dim.render("  #{@file_picker_index + 1}/#{@file_picker_entries.length}")
    end

    lines.join("\n")
  end

  def render_file_picker_status
    parts = ["enter: select", "backspace: up dir", "~: home"]
    parts << "esc: cancel"
    parts.join(" | ")
  end

  # ========== Image Rendering ==========

  # Center a rendered image (with ANSI escape codes) horizontally within a given width
  def center_image(img_str, target_width)
    return img_str unless img_str
    lines = img_str.split("\n")
    return img_str if lines.empty?
    # Measure visible width of first line (strip ANSI escapes)
    visible_width = lines.first.gsub(/\e\[[0-9;]*[A-Za-z]/, "").length
    pad = [(target_width - visible_width) / 2, 0].max
    padding = " " * pad
    lines.map { |l| "#{padding}#{l}" }.join("\n")
  end

  # Theme-aware logo renderer: transparent pixels -> surface color,
  # dark strokes -> white on dark themes, black on light themes.
  def render_logo_halfblocks(path, max_w, max_h, pixelate: nil)
    return nil unless path && File.exist?(path)

    image = ChunkyPNG::Image.from_file(path)
    pixel_h = max_h * 2

    scale_w = max_w.to_f / image.width
    scale_h = pixel_h.to_f / image.height
    scale = [scale_w, scale_h].min

    new_w = (image.width * scale).to_i.clamp(1, max_w)
    new_h = (image.height * scale).to_i.clamp(1, pixel_h)

    resized = image.resample_nearest_neighbor(new_w, new_h)

    if pixelate && pixelate > 1
      tiny_w = [new_w / pixelate, 2].max
      tiny_h = [new_h / pixelate, 2].max
      tiny = resized.resample_nearest_neighbor(tiny_w, tiny_h)
      resized = tiny.resample_nearest_neighbor(new_w, new_h)
    end

    # Parse surface color for background
    surf = Theme.SURFACE.delete("#")
    sr = surf[0..1].to_i(16); sg = surf[2..3].to_i(16); sb = surf[4..5].to_i(16)
    # Dark theme if surface luminance is low
    dark_theme = (0.299 * sr + 0.587 * sg + 0.114 * sb) / 255.0 < 0.5

    lines = []
    y = 0
    while y < new_h
      line = +""
      new_w.times do |x|
        top = resized[x, y]
        bottom = (y + 1 < new_h) ? resized[x, y + 1] : ChunkyPNG::Color::TRANSPARENT

        tr, tg, tb = logo_pixel_color(top, sr, sg, sb, dark_theme)
        br, bg_, bb = logo_pixel_color(bottom, sr, sg, sb, dark_theme)

        line << "\e[38;2;#{tr};#{tg};#{tb}m\e[48;2;#{br};#{bg_};#{bb}m\u2580\e[0m"
      end
      lines << line
      y += 2
    end

    lines.join("\n")
  rescue
    nil
  end

  def logo_pixel_color(pixel, sr, sg, sb, dark_theme)
    a = ChunkyPNG::Color.a(pixel)
    if a < 128
      [sr, sg, sb]
    else
      if dark_theme
        [255 - ChunkyPNG::Color.r(pixel), 255 - ChunkyPNG::Color.g(pixel), 255 - ChunkyPNG::Color.b(pixel)]
      else
        [ChunkyPNG::Color.r(pixel), ChunkyPNG::Color.g(pixel), ChunkyPNG::Color.b(pixel)]
      end
    end
  end

  def render_image_halfblocks(path, max_w, max_h, pixelate: nil, corner_radius: 0)
    return nil unless path && File.exist?(path)

    image = ChunkyPNG::Image.from_file(path)
    pixel_h = max_h * 2 # each row = 2 vertical pixels

    scale_w = max_w.to_f / image.width
    scale_h = pixel_h.to_f / image.height
    scale = [scale_w, scale_h].min

    new_w = (image.width * scale).to_i.clamp(1, max_w)
    new_h = (image.height * scale).to_i.clamp(1, pixel_h)

    resized = image.resample_nearest_neighbor(new_w, new_h)

    # Pixelation effect: downsample then scale back up for blocky look
    if pixelate && pixelate > 1
      tiny_w = [new_w / pixelate, 2].max
      tiny_h = [new_h / pixelate, 2].max
      tiny = resized.resample_nearest_neighbor(tiny_w, tiny_h)
      resized = tiny.resample_nearest_neighbor(new_w, new_h)
    end

    total_rows = (new_h + 1) / 2
    r = corner_radius

    lines = []
    y = 0
    row = 0
    while y < new_h
      line = +""
      new_w.times do |x|
        if r > 0 && corner_blank?(x, row, new_w, total_rows, r)
          line << " "
        else
          top = resized[x, y]
          bottom = (y + 1 < new_h) ? resized[x, y + 1] : ChunkyPNG::Color::BLACK

          tr = ChunkyPNG::Color.r(top)
          tg = ChunkyPNG::Color.g(top)
          tb = ChunkyPNG::Color.b(top)
          br = ChunkyPNG::Color.r(bottom)
          bg_ = ChunkyPNG::Color.g(bottom)
          bb = ChunkyPNG::Color.b(bottom)

          line << "\e[38;2;#{tr};#{tg};#{tb}m\e[48;2;#{br};#{bg_};#{bb}m\u2580\e[0m"
        end
      end
      lines << line
      y += 2
      row += 1
    end

    lines.join("\n")
  rescue
    nil
  end

  def corner_blank?(x, row, width, height, radius)
    # Top-left
    if x < radius && row < radius
      dx = radius - x - 0.5
      dy = radius - row - 0.5
      return dx * dx + dy * dy > radius * radius
    end
    # Top-right
    if x >= width - radius && row < radius
      dx = x - (width - radius) + 0.5
      dy = radius - row - 0.5
      return dx * dx + dy * dy > radius * radius
    end
    # Bottom-left
    if x < radius && row >= height - radius
      dx = radius - x - 0.5
      dy = row - (height - radius) + 0.5
      return dx * dx + dy * dy > radius * radius
    end
    # Bottom-right
    if x >= width - radius && row >= height - radius
      dx = x - (width - radius) + 0.5
      dy = row - (height - radius) + 0.5
      return dx * dx + dy * dy > radius * radius
    end
    false
  end

  def gradient_border_color
    colors = Theme.gradient(Theme.PRIMARY, Theme.ACCENT, 3)
    colors[1] # midpoint blend of primary and accent
  end

  # slot: stable ID for this image position (avoids flicker on re-render)
  def render_image_kitty(path, max_w, max_h, slot: 1)
    return nil unless path && File.exist?(path) && File.size(path) > 0

    image = ChunkyPNG::Image.from_file(path)
    png_data = File.binread(path)
    encoded = Base64.strict_encode64(png_data)

    # Compute cols/rows that fit within max_w × max_h while preserving aspect ratio.
    # Terminal cells are ~2x taller than wide (e.g. 8px × 16px).
    cell_ratio = 2.0
    img_w = image.width.to_f
    img_h = image.height.to_f

    # Convert image dimensions to "cell units" (cols and rows)
    # 1 col of image = 1 cell width, 1 row of image = cell_ratio cell widths of height
    img_cols = img_w
    img_rows = img_h / cell_ratio  # in cell-equivalent units

    scale_c = max_w / img_cols
    scale_r = max_h / img_rows
    scale = [scale_c, scale_r].min

    fit_cols = (img_cols * scale).floor.clamp(1, max_w)
    fit_rows = (img_rows * scale).floor.clamp(1, max_h)

    # Delete previous image in this slot, then transmit+display
    result = +"\e_Ga=d,d=I,i=#{slot},q=2\e\\"

    # Pass both c and r to hard-cap within bounds. The terminal fits the image
    # within this cell rectangle, preserving aspect ratio internally.
    # f=100=PNG, a=T=transmit+display, q=2=suppress responses
    chunks = encoded.scan(/.{1,4096}/)
    chunks.each_with_index do |chunk, i|
      more = (i < chunks.length - 1) ? 1 : 0
      if i == 0
        result << "\e_Gf=100,a=T,c=#{fit_cols},r=#{fit_rows},i=#{slot},q=2,m=#{more};#{chunk}\e\\"
      else
        result << "\e_Gm=#{more};#{chunk}\e\\"
      end
    end

    # Reserve rows so bubbletea accounts for image height
    result << ("\n" * [fit_rows - 1, 0].max)
    result
  rescue
    nil
  end

  def clear_kitty_images
    # Delete all kitty images - used when switching views
    print "\e_Ga=d,d=A,q=2\e\\"
  end

  # Route to halfblocks for lipgloss-compatible rendering
  # Kitty graphics are used only in fullscreen mode (render_fullscreen_image)
  # because lipgloss miscounts kitty escape sequences as visible characters
  def render_image(path, max_w, max_h, pixelate: nil, corner_radius: 0)
    render_image_halfblocks(path, max_w, max_h, pixelate: pixelate, corner_radius: corner_radius)
  end

  # ========== Rendering: Main View ==========

  def render_main_view
    header = render_header
    left = render_left_panel
    right = render_right_panel
    bottom = render_bottom_bar
    body = Lipgloss.join_horizontal(:top, left, right)
    Lipgloss.join_vertical(:left, header, body, bottom)
  end

  def render_header
    logo = Theme.gradient_text(" chewy ", Theme.PRIMARY, Theme.ACCENT)
    dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)

    # Provider badge for remote providers
    provider_badge = if @provider.provider_type == :api
      prov_label = Lipgloss::Style.new.background(Theme.SECONDARY).foreground(Theme.BAR_TEXT).bold(true)
        .render(" #{@provider.display_name} ")
      model_name = @remote_model_id || @provider.list_models.first&.dig(:id) || "default"
      " #{dim.render("\u2502")} #{prov_label} #{Lipgloss::Style.new.foreground(Theme.TEXT).bold(true).render(model_name)}"
    else
      ""
    end

    model_info = if @provider.provider_type == :local
      if @selected_model_path
        name = File.basename(@selected_model_path, File.extname(@selected_model_path))
        is_flux = flux_model?(@selected_model_path)
        cached_type = @model_types[@selected_model_path]

        quant = name.match(/[_-](Q\d_\w+|F16|F32|q\d_\w+|f16|f32)/i)&.captures&.first&.upcase

        type_label = if is_flux || cached_type == "FLUX"
          ok = flux_companions_present?
          pill_bg = ok ? Theme.SUCCESS : Theme.WARNING
          " #{Lipgloss::Style.new.background(pill_bg).foreground(Theme.SURFACE).bold(true).render(" FLUX ")}"
        elsif quant
          " #{Lipgloss::Style.new.background(Theme.SECONDARY).foreground(Theme.BAR_TEXT).bold(true).render(" #{quant} ")}"
        elsif cached_type
          " #{Lipgloss::Style.new.background(Theme.SECONDARY).foreground(Theme.BAR_TEXT).render(" #{cached_type} ")}"
        else
          " #{Lipgloss::Style.new.background(Theme.BORDER_DIM).foreground(Theme.TEXT).render(" SD ")}"
        end
        " #{dim.render("\u2502")} #{Lipgloss::Style.new.foreground(Theme.TEXT).bold(true).render(name)}#{type_label}"
      else
        " #{dim.render("\u2502")} #{dim.render("no model selected")}"
      end
    else
      provider_badge
    end

    img2img_badge = if @init_image_path && @provider.capabilities.img2img
      name = File.basename(@init_image_path)
      name = name[0, 20] + "..." if name.length > 23
      i2i = Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true)
      " #{dim.render("\u2502")} #{i2i.render("img2img")} #{dim.render(name)}"
    else
      ""
    end

    left = "#{logo}#{model_info}#{img2img_badge}"
    right = dim.render("[^y] provider  [^n] models ")

    # Right-align the hint
    left_visible = left.gsub(/\e\[[0-9;]*[A-Za-z]/, "").length
    right_visible = right.gsub(/\e\[[0-9;]*[A-Za-z]/, "").length
    gap = [@width - left_visible - right_visible, 1].max

    Lipgloss::Style.new.width(@width).background(Theme.SURFACE).render("#{left}#{' ' * gap}#{right}")
  end

  def left_panel_heights
    body_h = @height - 2  # header + bottom bar

    if @focus == FOCUS_PARAMS
      # Expanded: label + separator + N params + 2 border lines
      params_min = @param_display_keys.length + 4
      params_h = [params_min, (body_h * 0.30).to_i].max
    else
      # Compact: border + 1 line of inline params + border
      params_h = 3
    end

    remaining = [body_h - params_h, 8].max
    prompt_h = [(remaining * 0.6).to_i, 5].max
    negative_h = [remaining - prompt_h, 4].max

    # Rebalance if we overshot
    total = prompt_h + negative_h + params_h
    if total > body_h
      params_h = body_h - prompt_h - negative_h
    end

    [prompt_h, negative_h, params_h]
  end

  def render_left_panel
    lw = left_panel_width
    prompt_h, negative_h, params_h = left_panel_heights

    prompt_section = render_prompt_section(lw, prompt_h)
    negative_section = render_negative_section(lw, negative_h)
    params_section = render_params_section(lw, params_h)

    Lipgloss.join_vertical(:left, prompt_section, negative_section, params_section)
  end

  def render_right_panel
    rw = right_panel_width
    prompt_h, negative_h, params_h = left_panel_heights
    total_left = prompt_h + negative_h + params_h

    content = if @generating
      render_generating_preview(rw - 2, total_left)
    elsif @last_output_path && File.exist?(@last_output_path)
      render_image_preview(rw - 2, total_left)
    else
      render_empty_preview(rw - 2, total_left)
    end

    Lipgloss::Style.new
      .background(Theme.SURFACE)
      .width(rw - 2).height(total_left).padding(0, 1).render(content)
  end

  def render_image_preview(max_w, max_h)
    # Use cache if path hasn't changed and no reveal animation
    if @preview_cache && @preview_path == @last_output_path && @reveal_phase.nil?
      return @preview_cache
    end

    # Progressive reveal: phase 0=very blocky, 9=full res
    pixelate = if @reveal_phase
                 [64, 32, 20, 14, 10, 7, 5, 3, 2, nil][@reveal_phase]
               end

    img_str = render_image(@last_output_path, max_w, max_h, pixelate: pixelate, corner_radius: 3)
    if img_str
      result = center_image(img_str, max_w)
      # Only cache at full resolution
      if @reveal_phase.nil?
        @preview_cache = result
        @preview_path = @last_output_path
      end
      result
    else
      render_empty_preview(max_w, max_h)
    end
  end

  def render_generating_preview(max_w, max_h)
    dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    center = ->(s) { Lipgloss::Style.new.width(max_w).align(:center).render(s) }

    @gen_start_time ||= Time.now
    elapsed = (Time.now - @gen_start_time).to_i
    elapsed_str = elapsed >= 60 ? "#{elapsed / 60}m#{elapsed % 60}s" : "#{elapsed}s"

    # Animated dots
    dots = "\u2022" * ((elapsed % 3) + 1)
    dots_pad = " " * (3 - (elapsed % 3) - 1)

    # Gradient "Generating" text
    gen_text = Theme.gradient_text("Generating", Theme.PRIMARY, Theme.ACCENT)

    # Build status lines (centered)
    status_lines = []

    if @gen_total_steps > 0 && @gen_step > 0
      pct = @gen_step.to_f / @gen_total_steps
      pct_text = "#{(pct * 100).to_i}%"
      bar = @progress.view_as(pct)
      remaining = @gen_total_steps - @gen_step
      eta_str = if @gen_secs_per_step && @gen_secs_per_step > 0
        eta_secs = (remaining * @gen_secs_per_step).to_i
        eta_secs >= 60 ? "~#{eta_secs / 60}m#{eta_secs % 60}s" : "~#{eta_secs}s"
      else
        ""
      end
      speed_str = if @gen_secs_per_step && @gen_secs_per_step > 0
        @gen_secs_per_step >= 1.0 ? "#{@gen_secs_per_step.round(1)}s/it" : "#{(1.0 / @gen_secs_per_step).round(1)}it/s"
      else
        ""
      end

      status_lines << center.call("#{@spinner.view} #{gen_text} #{dim.render(elapsed_str)}")
      status_lines << ""
      status_lines << center.call(bar)
      detail = [
        Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true).render(pct_text),
        dim.render("#{@gen_step}/#{@gen_total_steps}"),
        dim.render(speed_str),
        dim.render(eta_str),
      ].reject { |s| s.gsub(/\e\[[0-9;]*[A-Za-z]/, "").strip.empty? }.join("  ")
      status_lines << center.call(detail)
    else
      status_text = @gen_status || "Starting"
      status_lines << center.call("#{@spinner.view} #{gen_text} #{dim.render(dots)}#{dots_pad}")
      status_lines << ""
      status_lines << center.call(dim.render(status_text))
    end

    if @gen_total_batch > 1
      batch_text = "Batch #{@gen_current_batch}/#{@gen_total_batch}"
      status_lines << center.call(Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render(batch_text))
    end

    # Try to show live preview image
    preview_img = load_gen_preview(max_w, max_h - status_lines.length - 1)

    if preview_img
      centered_img = center_image(preview_img, max_w)
      (centered_img + "\n" + status_lines.join("\n"))
    else
      # No preview yet — center status vertically
      pad_top = [(max_h - status_lines.length) / 2, 0].max
      (Array.new(pad_top, "") + status_lines).join("\n")
    end
  end

  def load_gen_preview(max_w, max_h)
    return nil unless @gen_preview_path && File.exist?(@gen_preview_path)

    begin
      mtime = File.mtime(@gen_preview_path)
      size = File.size(@gen_preview_path)
      return nil if size == 0

      # Use cache if file hasn't changed
      if @gen_preview_cache && @gen_preview_mtime == mtime
        return @gen_preview_cache
      end

      img_str = render_image(@gen_preview_path, max_w, max_h, corner_radius: 3)
      if img_str
        @gen_preview_cache = img_str
        @gen_preview_mtime = mtime
      end
      img_str
    rescue
      nil
    end
  end

  def render_empty_preview(max_w, max_h)
    dim = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
    key_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    center = ->(s) { Lipgloss::Style.new.width(max_w).align(:center).render(s) }

    # Show logo in empty preview area
    logo_path = File.join(__dir__, "logo.png")
    logo_img = if File.exist?(logo_path)
      logo_h = [max_h - 10, 4].max
      render_logo_halfblocks(logo_path, max_w - 4, logo_h)
    end

    lines = []
    if logo_img
      centered_logo = center_image(logo_img, max_w)
      lines += centered_logo.split("\n")
    end
    lines << ""
    lines << center.call(Theme.gradient_text("Ready to create", Theme.PRIMARY, Theme.ACCENT))
    lines << ""

    # Styled shortcut hints — left-aligned block, centered as a whole
    hints = [
      ["enter", "generate image"],
      ["^n", "select model"],
      ["^d", "download models"],
      ["^p", "load preset"],
    ]
    hint_lines = hints.map { |k, d| "#{key_style.render(k.ljust(7))} #{desc_style.render(d)}" }
    max_hint_w = hints.map { |k, d| 7 + 1 + d.length }.max
    pad = [(max_w - max_hint_w) / 2, 0].max
    hint_lines.each { |l| lines << (" " * pad) + l }

    pad_top = [(max_h - lines.length) / 2, 0].max
    (Array.new(pad_top, "") + lines).join("\n")
  end

  def render_wrapped_input(input, max_lines:)
    value = input.value
    width = [input.width, 1].max
    max_lines = [max_lines, 1].max

    return input.view if value.empty? || value.chars.length <= width

    lines, positions = wrapped_input_layout(value, width)
    cursor_line, cursor_col = positions[input.position]
    start_line = [cursor_line - max_lines + 1, 0].max
    visible_lines = lines[start_line, max_lines] || []

    visible_lines.map.with_index do |line, offset|
      line_index = start_line + offset
      if input.focused? && line_index == cursor_line
        line_chars = line.chars
        before = line_chars[0...cursor_col].join
        char = line_chars[cursor_col] || " "
        after = line_chars[(cursor_col + 1)..]&.join.to_s

        input.cursor.char = char
        "#{render_input_text(before, input.text_style)}#{input.cursor.view}#{render_input_text(after, input.text_style)}"
      else
        render_input_text(line, input.text_style)
      end
    end.join("\n")
  end

  def wrapped_input_layout(value, width)
    chars = value.chars
    lines = [[]]
    positions = Array.new(chars.length + 1)
    line_index = 0

    chars.each_with_index do |char, idx|
      if lines[line_index].length >= width
        line_index += 1
        lines << []
      end

      positions[idx] = [line_index, lines[line_index].length]

      # Skip the whitespace that triggered the wrap so continuation lines start on content.
      next if line_index.positive? && lines[line_index].empty? && char == " "

      lines[line_index] << char
    end

    if lines[line_index].length >= width
      line_index += 1
      lines << []
    end

    positions[chars.length] = [line_index, lines[line_index].length]
    [lines.map(&:join), positions]
  end

  def render_input_text(text, style)
    return "" if text.empty?

    style ? style.render(text) : text
  end

  def render_prompt_section(tw, box_h)
    focused = @focus == FOCUS_PROMPT

    label_style = Lipgloss::Style.new.foreground(focused ? Theme.PRIMARY : Theme.TEXT_DIM).bold(focused)
    label = label_style.render("Prompt")

    lora_tags = if @selected_loras.any?
      pill = Lipgloss::Style.new.background(Theme.ACCENT).foreground(Theme.SURFACE).bold(true)
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      tags = @selected_loras.map { |l| pill.render(" #{l[:name]}:#{l[:weight]} ") }
      "\n#{dim.render("LoRA")} #{tags.join(' ')}"
    else
      ""
    end

    prompt_lines = [box_h - 4 - lora_tags.count("\n"), 1].max
    prompt_view = render_wrapped_input(@prompt_input, max_lines: prompt_lines)
    content = "#{label}\n#{prompt_view}#{lora_tags}"

    border_color = focused ? gradient_border_color : Theme.BORDER_DIM
    Lipgloss::Style.new.border(:rounded).border_foreground(border_color).background(Theme.SURFACE)
      .width(tw - 2).height(box_h - 2).render(content)
  end

  def render_negative_section(tw, box_h)
    focused = @focus == FOCUS_NEGATIVE

    label_style = Lipgloss::Style.new.foreground(focused ? Theme.ACCENT : Theme.TEXT_DIM).bold(focused)
    label = label_style.render("Negative Prompt")

    negative_lines = [box_h - 3, 1].max
    negative_view = render_wrapped_input(@negative_input, max_lines: negative_lines)
    content = "#{label}\n#{negative_view}"

    border_color = focused ? gradient_border_color : Theme.BORDER_DIM
    Lipgloss::Style.new.border(:rounded).border_foreground(border_color).background(Theme.SURFACE)
      .width(tw - 2).height(box_h - 2).render(content)
  end

  def render_params_section(tw, box_h)
    focused = @focus == FOCUS_PARAMS

    unless focused
      return render_params_compact(tw, box_h)
    end


    label_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    label = label_style.render("Parameters")

    dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    separator = dim.render("─" * [tw - 6, 4].max)

    param_lines = @param_display_keys.each_with_index.map do |key, i|
      label_text = param_label(key)
      value = param_value(key)
      selected = i == @param_index

      val_style = Lipgloss::Style.new.foreground(Theme.TEXT)
      display = if @editing_param && selected
        Lipgloss::Style.new.foreground(Theme.ACCENT).render(@param_edit_buffer) +
          Lipgloss::Style.new.foreground(Theme.ACCENT).blink(true).render("_")
      elsif key == :sampler || key == :scheduler
        arrow = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
        "#{arrow.render("<")} #{val_style.render(value.to_s)} #{arrow.render(">")}"
      elsif key == :seed && value == -1
        Lipgloss::Style.new.foreground(Theme.TEXT_DIM).italic(true).render("random")
      elsif key == :strength
        hint = @init_image_path ? "" : Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).render(" (^b to set image)")
        "#{val_style.render(value.to_s)}#{hint}"
      else
        val_style.render(value.to_s)
      end

      if selected
        cursor = Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true).render("> ")
        lbl = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true).render(label_text)
        "#{cursor}#{lbl}  #{display}"
      else
        "  #{dim.render(label_text)}  #{display}"
      end
    end

    content = "#{label}\n#{separator}\n#{param_lines.join("\n")}"
    Lipgloss::Style.new
      .border(:rounded).border_foreground(gradient_border_color)
      .background(Theme.SURFACE)
      .width(tw - 2).height(box_h - 2).padding(0, 1).render(content)
  end

  def render_params_compact(tw, box_h)
    dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    val = Lipgloss::Style.new.foreground(Theme.TEXT)

    seed_display = @params[:seed] == -1 ? "random" : @params[:seed].to_s
    items = [
      "#{dim.render('steps')} #{val.render(@params[:steps].to_s)}",
      "#{dim.render('cfg')} #{val.render(@params[:cfg_scale].to_s)}",
      val.render("#{@params[:width]}\u00d7#{@params[:height]}"),
      "#{dim.render('seed')} #{val.render(seed_display)}",
      val.render(@sampler),
    ]
    items << val.render(@scheduler) if @scheduler != "discrete"

    content = items.join("  ")

    Lipgloss::Style.new
      .border(:rounded).border_foreground(Theme.BORDER_DIM).background(Theme.SURFACE)
      .width(tw - 2).height(box_h - 2).padding(0, 1).render(content)
  end

  def param_label(key)
    case key
    when :steps then "Steps    "
    when :cfg_scale then "CFG Scale"
    when :width then "Width    "
    when :height then "Height   "
    when :seed then "Seed     "
    when :sampler then "Sampler  "
    when :batch then "Batch    "
    when :strength then "Strength "
    when :scheduler then "Schedule "
    when :threads then "Threads  "
    else key.to_s.ljust(9)
    end
  end

  def render_bottom_bar
    # Right side: context shortcuts
    key_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).bold(true)
    desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
    sep = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).render(" \u2502 ")
    keys = context_keys
    right = keys.map { |k, d| "#{key_style.render(k)} #{desc_style.render(d)}" }.join(sep)
    right_visible = right.gsub(/\e\[[0-9;]*[A-Za-z]/, "").length

    # Left side: status info
    if @error_message
      bar = Lipgloss::Style.new.background(Theme.ERROR).foreground(Theme.BAR_TEXT).width(@width).padding(0, 1)
      return bar.render("! #{@error_message}")
    end

    if @companion_downloading
      bar_style = Lipgloss::Style.new.background(Theme.SECONDARY).foreground(Theme.BAR_TEXT).width(@width).padding(0, 1)
      current = (@companion_dest && File.exist?(@companion_dest)) ? File.size(@companion_dest) : 0
      total = @companion_download_size || 0
      pct = total > 0 ? (current.to_f / total) : 0
      progress_bar = @progress.view_as(pct.clamp(0.0, 1.0))
      size_text = total > 0 ?
        "#{format_bytes(current)} / #{format_bytes(total)}" :
        format_bytes(current)
      return bar_style.render("#{@spinner.view} #{@companion_current_file} #{progress_bar} #{size_text} (#{@companion_remaining} remaining)")
    end

    if @status_message
      left = @status_message
      bg = Theme.PRIMARY; fg = Theme.BAR_TEXT
    elsif @last_output_path && @last_generation_time
      bg = if @reveal_phase && @reveal_phase < REVEAL_PHASES
        progress = @reveal_phase.to_f / (REVEAL_PHASES - 1)
        sweep_colors = Theme.gradient(Theme.SURFACE, Theme.PRIMARY, 10)
        sweep_colors[(progress * 9).to_i]
      else
        Theme.PRIMARY
      end
      fg = if @reveal_phase && @reveal_phase < REVEAL_PHASES / 2
        Theme.TEXT_DIM
      else
        Theme.BAR_TEXT
      end
      left = "output: #{File.basename(@last_output_path)} \u2502 #{@last_generation_time}s"
      left += " \u2502 seed #{@last_seed}" if @last_seed
    else
      # No status — just show shortcuts on surface background
      return Lipgloss::Style.new.width(@width).padding(0, 1).background(Theme.SURFACE).render(right)
    end

    # Combine left info + right shortcuts in one bar
    left_visible = left.gsub(/\e\[[0-9;]*[A-Za-z]/, "").length
    gap = [@width - left_visible - right_visible - 4, 1].max
    bar = Lipgloss::Style.new.background(bg).foreground(fg).width(@width).padding(0, 1)
    bar.render("#{left}#{' ' * gap}#{right}")
  end

  def context_keys
    keys = case @focus
    when FOCUS_PROMPT
      [["enter", "generate"], ["tab", "focus"], ["^n", "models"]]
    when FOCUS_NEGATIVE
      [["enter", "generate"], ["tab", "focus"], ["^n", "models"]]
    when FOCUS_PARAMS
      [["enter", "edit"], ["j/k", "nav"], ["tab", "focus"]]
    else
      [["tab", "focus"], ["^n", "models"]]
    end

    keys << ["^x", "cancel"] if @generating
    keys << ["^e", "open"] if @last_output_path && !@generating
    keys << ["^f", "fullscreen"] if @last_output_path && !@generating
    keys += [["^y", "provider"], ["^d", "download"], ["^a", "gallery"], ["^p", "preset"]]
    keys << ["^q", "quit"]
    keys
  end

  # ========== Rendering: Models Overlay ==========

  def render_models_content
    return Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("No models found — press d to download") if @model_paths.empty?
    return Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("Loading...") unless @model_list

    dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    accent = Lipgloss::Style.new.foreground(Theme.ACCENT)

    list_view = @model_list.view

    # Show metadata for highlighted model
    idx = @model_list.selected_index rescue 0
    meta = ""
    if @model_paths.any? && idx < @model_paths.length
      path = @model_paths[idx]
      if File.exist?(path)
        stat = File.stat(path)
        ext = File.extname(path).delete(".").upcase
        is_flux = flux_model?(path)

        type_tag = if is_flux
          ok = flux_companions_present?
          s = Lipgloss::Style.new.foreground(ok ? Theme.SUCCESS : Theme.WARNING).bold(true)
          s.render(ok ? "FLUX" : "FLUX (needs companions)")
        else
          dim.render("SD")
        end

        pin = @pinned_models.include?(path) ? accent.render(" [pinned]") : ""
        meta = "\n#{accent.render(format_bytes(stat.size))} #{dim.render("|")} #{dim.render(ext)} #{dim.render("|")} #{type_tag}#{pin}"
        meta += "\n#{dim.render(path)}"
      end
    end

    "#{list_view}#{meta}"
  end

  def render_models_status
    "enter: select | f: pin | d: download | del: delete | esc: close"
  end

  # ========== Rendering: Overlay Panels ==========

  def render_overlay_panel(title, content, status_text)
    # Title bar
    title_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    title_bar = "#{title_style.render(title)}"
    separator = dim.render("─" * (@width - 6))

    body_content = "#{title_bar}\n#{separator}\n#{content}"
    body = Lipgloss::Style.new
      .border(:rounded).border_foreground(Theme.PRIMARY).background(Theme.SURFACE)
      .width(@width - 4).height(@height - 4).padding(0, 1).render(body_content)

    # Status uses help bar style
    key_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).bold(true)
    desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
    status = Lipgloss::Style.new.width(@width).padding(0, 1).background(Theme.SURFACE)
      .render(format_help_text(status_text, key_style, desc_style))

    Lipgloss.join_vertical(:left, body, status)
  end

  def format_help_text(text, key_style, desc_style)
    # Parse "key: action | key: action" format into styled text
    parts = text.split(" | ")
    sep = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).render(" | ")
    parts.map do |part|
      if part.include?(": ")
        k, d = part.split(": ", 2)
        "#{key_style.render(k)} #{desc_style.render(d)}"
      else
        desc_style.render(part)
      end
    end.join(sep)
  end

  def render_download_view
    content = if @fetching
      "#{@spinner.view} Searching HuggingFace..."
    elsif @download_view == :recommended && @recommended_list
      @recommended_list.view
    elsif @download_view == :repos && @repo_list
      @repo_list.view
    elsif @download_view == :files && @file_list
      @file_list.view
    else
      Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("Loading...")
    end

    title = case @download_view
    when :recommended then "Recommended Models"
    when :files then "Files in #{@selected_repo_id}"
    else "Download Models"
    end
    title_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    separator = dim.render("─" * (@width - 6))

    # Search bar (only on repos view)
    search_bar = if @download_view == :repos
      border_color = @download_search_focused ? Theme.BORDER_FOCUS : Theme.BORDER_DIM
      search_label = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("Search: ")
      Lipgloss::Style.new.border(:rounded).border_foreground(border_color).background(Theme.SURFACE)
        .width(@width - 8).render("#{search_label}#{@download_search_input.view}")
    end

    parts = [title_style.render(title), separator]
    parts << search_bar if search_bar
    parts << content
    body_content = parts.join("\n")

    body = Lipgloss::Style.new
      .border(:rounded).border_foreground(Theme.PRIMARY).background(Theme.SURFACE)
      .width(@width - 4).height(@height - 4).padding(0, 1).render(body_content)
    status = render_download_status_bar
    Lipgloss.join_vertical(:left, body, status)
  end

  def render_download_status_bar
    if @model_downloading
      current = (File.size(@download_dest) rescue 0)
      pct = @download_total > 0 ? (current.to_f / @download_total) : 0
      bar = @progress.view_as(pct.clamp(0.0, 1.0))
      size_text = @download_total > 0 ?
        "#{format_bytes(current)} / #{format_bytes(@download_total)}" :
        format_bytes(current)

      download_bar = Lipgloss::Style.new.background(Theme.SECONDARY).foreground(Theme.BAR_TEXT).width(@width).padding(0, 1)
      return download_bar.render("#{@spinner.view} #{@download_filename} #{bar} #{size_text}")
    end

    if @error_message
      error_bar = Lipgloss::Style.new.background(Theme.ERROR).foreground(Theme.BAR_TEXT).width(@width).padding(0, 1)
      return error_bar.render("! #{@error_message}")
    end

    status_text = if @status_message
      @status_message
    elsif @download_view == :recommended
      "enter: download | esc: close"
    elsif @download_view == :files
      "enter: download | esc: back"
    elsif @download_search_focused
      "enter: search | esc: unfocus | tab: toggle"
    else
      "tab: search | enter: browse | esc: back"
    end

    key_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).bold(true)
    desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
    Lipgloss::Style.new.width(@width).padding(0, 1).background(Theme.SURFACE)
      .render(format_help_text(status_text, key_style, desc_style))
  end

  def render_history_content
    @history_list ? @history_list.view : Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("No history")
  end

  def render_history_status
    "enter: load params | esc: close"
  end

  def render_fullscreen_image
    return render_empty_preview(@width, @height) unless @fullscreen_image_path

    dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    hint = dim.render("press any key to go back")

    img_h = @height - 2
    img_w = @width

    if @kitty_graphics
      # Kitty mode: raw escape sequence, no lipgloss wrapping
      img = render_image_kitty(@fullscreen_image_path, img_w, img_h, slot: 10)
      if img
        "#{img}\n#{hint}"
      else
        # Fallback to halfblocks
        img = render_image_halfblocks(@fullscreen_image_path, img_w, img_h)
        "#{img || "(failed to load)"}\n#{hint}"
      end
    else
      # Halfblock mode
      img = render_image_halfblocks(@fullscreen_image_path, img_w, img_h)
      "#{img || "(failed to load)"}\n#{hint}"
    end
  end

  def render_gallery_view
    dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    title_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    sel_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    meta_key = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    meta_val = Lipgloss::Style.new.foreground(Theme.TEXT)

    if @gallery_images.empty?
      content = dim.render("No images found in #{@output_dir}")
      return render_overlay_panel("Gallery", content, "esc: close")
    end

    inner_h = @height - 6
    list_w = [(@width * 0.35).to_i, 30].max
    preview_w = @width - list_w - 8

    # -- Left: image list --
    visible = inner_h - 2
    half = visible / 2
    scroll_offset = if @gallery_index < half
                      0
                    elsif @gallery_index >= @gallery_images.length - half
                      [@gallery_images.length - visible, 0].max
                    else
                      @gallery_index - half
                    end

    list_lines = @gallery_images.each_with_index.map do |img, i|
      next nil if i < scroll_offset || i >= scroll_offset + visible

      fname = File.basename(img[:path], ".png")
      prompt = (img[:meta]["prompt"] || "")[0, list_w - 6]
      label = prompt.empty? ? fname : prompt
      if i == @gallery_index
        sel_style.render("> #{label}")
      else
        "  #{dim.render(label)}"
      end
    end.compact

    counter = dim.render("#{@gallery_index + 1}/#{@gallery_images.length}")
    list_content = list_lines.join("\n") + "\n" + counter
    list_panel = Lipgloss::Style.new
      .border(:rounded).border_foreground(Theme.PRIMARY).background(Theme.SURFACE)
      .width(list_w).height(inner_h).padding(0, 1)
      .render(list_content)

    # -- Right: preview + metadata --
    entry = @gallery_images[@gallery_index]
    meta = entry[:meta]

    info_lines = []
    info_lines << "#{meta_key.render("File:")} #{meta_val.render(File.basename(entry[:path]))}"
    info_lines << "#{meta_key.render("Prompt:")} #{meta_val.render((meta["prompt"] || "-")[0, preview_w - 12])}" if meta["prompt"]
    info_lines << "#{meta_key.render("Model:")} #{meta_val.render(File.basename(meta["model"] || "-"))}" if meta["model"]
    if meta["steps"] || meta["seed"]
      parts = []
      parts << "steps:#{meta["steps"]}" if meta["steps"]
      parts << "cfg:#{meta["cfg_scale"]}" if meta["cfg_scale"]
      parts << "#{meta["width"]}x#{meta["height"]}" if meta["width"]
      parts << "seed:#{meta["seed"]}" if meta["seed"]
      info_lines << meta_key.render(parts.join(" | "))
    end
    if meta["generation_time_seconds"]
      info_lines << "#{meta_key.render("Time:")} #{meta_val.render("#{meta["generation_time_seconds"]}s")}"
    end

    info_h = info_lines.length + 1
    thumb_h = [inner_h - info_h - 2, 6].max

    thumb = gallery_thumb(entry[:path], preview_w - 4, thumb_h)
    thumb ||= dim.render("(no preview)")
    preview_content = thumb + "\n" + info_lines.join("\n")
    preview_panel = Lipgloss::Style.new
      .border(:rounded).border_foreground(Theme.BORDER_DIM).background(Theme.SURFACE)
      .width(preview_w).height(inner_h).padding(0, 1)
      .render(preview_content)

    body = Lipgloss.join_horizontal(:top, list_panel, preview_panel)

    title_bar = title_style.render("Gallery") + "  " + dim.render("#{@gallery_images.length} images")
    outer = Lipgloss::Style.new.padding(0, 1).render(
      Lipgloss.join_vertical(:left, title_bar, body)
    )

    status_text = "enter: fullscreen | ^e: open external | del: delete | j/k: navigate | esc: close"
    key_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).bold(true)
    desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
    status = Lipgloss::Style.new.width(@width).padding(0, 1).background(Theme.SURFACE)
      .render(format_help_text(status_text, key_style, desc_style))

    Lipgloss.join_vertical(:left, outer, status)
  end

  def gallery_thumb(path, max_w, max_h)
    cached = @gallery_thumb_cache[path]
    return cached if cached

    # Limit cache to 20 entries to avoid excessive memory use
    @gallery_thumb_cache.shift if @gallery_thumb_cache.size >= 20

    thumb = render_image(path, max_w, max_h)
    @gallery_thumb_cache[path] = thumb if thumb
    thumb
  end

  def render_lora_content
    if @available_loras.empty?
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      return dim.render("No LoRAs found in #{@lora_dir}")
    end

    lines = @available_loras.each_with_index.map do |lora, i|
      sel = @selected_loras.find { |l| l[:path] == lora[:path] }
      selected = i == @lora_index

      check = if sel
        Lipgloss::Style.new.foreground(Theme.SUCCESS).render("[x]")
      else
        Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("[ ]")
      end

      weight = if @editing_lora_weight && selected
        Lipgloss::Style.new.foreground(Theme.ACCENT).render(" w:#{@lora_weight_buffer}_")
      elsif sel
        Lipgloss::Style.new.foreground(Theme.ACCENT).render(" w:#{sel[:weight]}")
      else
        ""
      end

      if selected
        cursor = Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true).render("> ")
        name = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true).render(lora[:name])
        "#{cursor}#{check} #{name}#{weight}"
      else
        "  #{check} #{lora[:name]}#{weight}"
      end
    end
    lines.join("\n")
  end

  def render_lora_status
    if @editing_lora_weight
      "enter: confirm | esc: cancel"
    else
      "space: toggle | +/-: weight | w: edit | esc: close"
    end
  end

  def render_preset_content
    all = all_presets
    if all.empty?
      return Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("No presets")
    end

    dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)

    lines = all.each_with_index.map do |p, i|
      selected = i == @preset_index
      d = p[:data]
      tag = p[:builtin] ?
        Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).render(" built-in") :
        Lipgloss::Style.new.foreground(Theme.SUCCESS).render(" custom")

      desc_parts = [
        "#{d['steps']}steps",
        d['sampler'],
        "#{d['width']}x#{d['height']}",
      ]
      desc = dim.render(desc_parts.join(" / "))

      if selected
        cursor = Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true).render("> ")
        name = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true).render(p[:name])
        "#{cursor}#{name}#{tag}\n    #{desc}"
      else
        "  #{p[:name]}#{tag}\n    #{desc}"
      end
    end

    result = lines.join("\n")
    if @naming_preset
      prompt_style = Lipgloss::Style.new.foreground(Theme.ACCENT)
      result += "\n\n#{prompt_style.render("Name:")} #{@preset_name_buffer}_"
    elsif @confirm_delete_preset
      warn_style = Lipgloss::Style.new.foreground(Theme.ERROR).bold(true)
      result += "\n\n#{warn_style.render("Delete this preset?")} #{dim.render("y/n")}"
    end
    result
  end

  def render_preset_status
    if @naming_preset
      "enter: save | esc: cancel"
    elsif @confirm_delete_preset
      "y: confirm | any: cancel"
    else
      "enter: load | s: save | d: delete | esc: close"
    end
  end

  # ========== Theme Picker Overlay ==========

  def handle_theme_key(message)
    key = message.to_s
    case key
    when "esc", "q"
      # Revert to original theme on cancel
      Theme.set(@theme_original)
      return close_overlay
    when "enter"
      # Confirm selection
      save_config
      @status_message = "Theme: #{Theme.current_name}"
      return close_overlay
    when "up", "k"
      @theme_index = (@theme_index - 1) % THEME_NAMES.length
      Theme.set(THEME_NAMES[@theme_index])
      return [self, nil]
    when "down", "j"
      @theme_index = (@theme_index + 1) % THEME_NAMES.length
      Theme.set(THEME_NAMES[@theme_index])
      return [self, nil]
    end
    [self, nil]
  end

  def render_theme_content
    lines = THEME_NAMES.each_with_index.map do |name, i|
      theme = THEMES[name]
      selected = i == @theme_index

      # Color swatch: show key colors as colored blocks
      swatch = [
        theme["primary"], theme["secondary"], theme["accent"],
        theme["success"], theme["warning"], theme["error"],
      ].map { |c| Lipgloss::Style.new.foreground(c).render("\u2588\u2588") }.join(" ")

      if selected
        cursor = Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true).render("> ")
        label = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true).render(name)
        "#{cursor}#{label}\n    #{swatch}"
      else
        dim_label = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render(name)
        "  #{dim_label}\n    #{swatch}"
      end
    end

    lines.join("\n")
  end

  def render_theme_status
    "up/down: browse (live preview) | enter: apply | esc: cancel"
  end

  # ========== Provider Overlay ==========

  def handle_provider_key(message)
    key = message.to_s
    case key
    when "esc", "q"
      return close_overlay
    when "up", "k"
      @provider_index = (@provider_index - 1) % @providers.length
      return [self, nil]
    when "down", "j"
      @provider_index = (@provider_index + 1) % @providers.length
      return [self, nil]
    when "left"
      selected = @providers[@provider_index]
      if selected.provider_type == :api && selected.list_models.any?
        models = selected.list_models
        cur = models.index { |m| m[:id] == @remote_model_id } || 0
        @remote_model_index = (cur - 1) % models.length
        @remote_model_id = models[@remote_model_index][:id]
        update_param_keys if selected.id == @provider.id
      end
      return [self, nil]
    when "right"
      selected = @providers[@provider_index]
      if selected.provider_type == :api && selected.list_models.any?
        models = selected.list_models
        cur = models.index { |m| m[:id] == @remote_model_id } || 0
        @remote_model_index = (cur + 1) % models.length
        @remote_model_id = models[@remote_model_index][:id]
        update_param_keys if selected.id == @provider.id
      end
      return [self, nil]
    when "k"
      selected = @providers[@provider_index]
      if selected.needs_api_key?
        @provider = selected  # set so the api_key overlay knows which provider
        @overlay = nil
        return open_overlay(:api_key)
      end
      return [self, nil]
    when "enter"
      @provider = @providers[@provider_index]
      if @provider.provider_type == :api && @provider.list_models.any?
        # Reset to first model if current model isn't in this provider's list
        models = @provider.list_models
        unless models.any? { |m| m[:id] == @remote_model_id }
          @remote_model_id = models.first[:id]
          @remote_model_index = 0
        end
      end
      update_param_keys
      save_config
      @status_message = "Provider: #{@provider.display_name}"
      return close_overlay
    end
    [self, nil]
  end

  def render_provider_content
    dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    lines = @providers.each_with_index.map do |prov, i|
      selected = i == @provider_index
      active = prov.id == @provider.id

      # Status indicator
      status = if prov.needs_api_key?
        if prov.api_key_set?
          Lipgloss::Style.new.foreground(Theme.SUCCESS).render(" \u2713")
        else
          hint = selected ? " \u2014 press k to set key" : ""
          Lipgloss::Style.new.foreground(Theme.ERROR).render(" \u2717 no key#{hint}")
        end
      else
        Lipgloss::Style.new.foreground(Theme.SUCCESS).render(" \u2713")
      end

      active_badge = active ? Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true).render(" [active]") : ""

      name = if selected
        cursor = Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true).render("> ")
        label = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true).render(prov.display_name)
        "#{cursor}#{label}#{status}#{active_badge}"
      else
        "  #{dim.render(prov.display_name)}#{status}#{active_badge}"
      end

      # Show model selector for API providers when selected
      model_line = if selected && prov.provider_type == :api && prov.list_models.any?
        models = prov.list_models
        current_id = @remote_model_id || models.first[:id]
        cur_model = models.find { |m| m[:id] == current_id } || models.first
        arrow = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
        model_name = Lipgloss::Style.new.foreground(Theme.TEXT).render(cur_model[:name])
        model_desc = dim.render(" - #{cur_model[:desc]}")
        "\n    #{dim.render("Model:")} #{arrow.render("<")} #{model_name} #{arrow.render(">")}#{model_desc}"
      else
        ""
      end

      "#{name}#{model_line}"
    end

    lines.join("\n\n")
  end

  def render_provider_status
    "up/down: select | left/right: model | k: set key | enter: activate | esc: close"
  end

  # ========== API Key Overlay ==========

  def handle_api_key_key(message)
    key = message.to_s
    case key
    when "esc"
      @api_key_input.value = ""
      return close_overlay
    when "enter"
      api_key = @api_key_input.value.strip
      if api_key.empty?
        @error_message = "API key cannot be empty"
        return [self, nil]
      end
      @provider.store_api_key(api_key)
      @api_key_input.value = ""
      @overlay = nil
      @error_message = nil
      @status_message = "#{@provider.display_name} API key saved"
      case @focus
      when FOCUS_PROMPT then @prompt_input.focus
      when FOCUS_NEGATIVE then @negative_input.focus
      end
      return [self, nil]
    end
    @api_key_input, cmd = @api_key_input.update(message)
    [self, cmd]
  end

  def render_api_key_content
    dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    accent = Lipgloss::Style.new.foreground(Theme.ACCENT)
    prov = @provider

    lines = []
    lines << dim.render("#{prov.display_name} requires an API key to generate images.")
    lines << ""
    if prov.api_key_setup_url
      lines << dim.render("1. Go to  ") + accent.render(prov.api_key_setup_url)
      lines << dim.render("2. Create a new API key")
      lines << dim.render("3. Paste it below")
    else
      lines << dim.render("1. Set ") + accent.render(prov.api_key_env_var) + dim.render(" environment variable")
      lines << dim.render("   or paste your key below")
    end
    lines << ""
    lines << "Key: #{@api_key_input.view}"
    lines << ""
    lines << dim.render("Saved to ~/.config/sdtui/keys/ (chmod 600)")
    lines << ""
    lines << dim.render("You can also set ") + accent.render(prov.api_key_env_var) + dim.render(" in your shell instead.")
    lines.join("\n")
  end

  def render_api_key_status
    "enter: save | esc: cancel"
  end

  # ========== HF Token Overlay ==========

  def handle_hf_token_key(message)
    key = message.to_s
    case key
    when "esc"
      @hf_token_pending_action = nil
      @hf_token_input.value = ""
      return close_overlay
    when "enter"
      token = @hf_token_input.value.strip
      if token.empty?
        @error_message = "Token cannot be empty"
        return [self, nil]
      end
      save_hf_token(token)
      @hf_token_input.value = ""
      pending = @hf_token_pending_action
      @hf_token_pending_action = nil
      @overlay = nil
      @status_message = "Token saved"
      case @focus
      when FOCUS_PROMPT then @prompt_input.focus
      when FOCUS_NEGATIVE then @negative_input.focus
      end
      # Resume the action that triggered the token prompt
      return download_flux_companions if pending == :flux_companions
      return [self, nil]
    end
    @hf_token_input, cmd = @hf_token_input.update(message)
    [self, cmd]
  end

  def render_hf_token_content
    dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    accent = Lipgloss::Style.new.foreground(Theme.ACCENT)

    lines = []
    lines << dim.render("FLUX models require a HuggingFace token to download companion files.")
    lines << ""
    lines << dim.render("1. Go to  ") + accent.render("huggingface.co/settings/tokens")
    lines << dim.render("2. Create a token (read access is enough)")
    lines << dim.render("3. Accept FLUX model terms at")
    lines << "   " + accent.render("huggingface.co/black-forest-labs/FLUX.1-schnell")
    lines << dim.render("4. Paste your token below")
    lines << ""
    lines << "Token: #{@hf_token_input.view}"
    lines << ""
    lines << dim.render("Saved to ~/.cache/huggingface/token")
    lines.join("\n")
  end

  def render_hf_token_status
    "enter: save | esc: cancel"
  end

  # ========== HTTP Helpers ==========

  def hf_get(uri, limit = 5)
    raise "Too many redirects" if limit == 0
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.read_timeout = 30; http.open_timeout = 10
    req = Net::HTTP::Get.new(uri)
    req["Accept"] = "application/json"; req["User-Agent"] = "chewy-tui/1.0"
    resp = http.request(req)
    case resp
    when Net::HTTPRedirection then hf_get(URI.parse(resp["location"]), limit - 1)
    when Net::HTTPSuccess then resp
    else raise "HTTP #{resp.code}: #{resp.message}"
    end
  end

  # Convert Theme.SURFACE hex color to ANSI 24-bit background escape sequence
  def surface_bg_escape
    hex = Theme.SURFACE.sub("#", "")
    r = hex[0, 2].to_i(16)
    g = hex[2, 2].to_i(16)
    b = hex[4, 2].to_i(16)
    "\e[48;2;#{r};#{g};#{b}m"
  end

  # Remove background color from the 4 rounded corner characters
  # so they appear transparent against the terminal background
  def clear_corner_backgrounds(str)
    lines = str.split("\n")
    return str if lines.length < 2

    # First line: clear bg on ╭ and ╮
    lines[0] = lines[0]
      .sub(/(\e\[[\d;]*m)*(\e\[48;2;[\d;]+m)(\e\[[\d;]*m)*(\u256D)/) { "#{$1}\e[49m#{$3}#{$4}" }
      .sub(/(\e\[[\d;]*m)*(\e\[48;2;[\d;]+m)(\e\[[\d;]*m)*(\u256E)/) { "#{$1}\e[49m#{$3}#{$4}" }

    # Last line: clear bg on ╰ and ╯
    lines[-1] = lines[-1]
      .sub(/(\e\[[\d;]*m)*(\e\[48;2;[\d;]+m)(\e\[[\d;]*m)*(\u2570)/) { "#{$1}\e[49m#{$3}#{$4}" }
      .sub(/(\e\[[\d;]*m)*(\e\[48;2;[\d;]+m)(\e\[[\d;]*m)*(\u256F)/) { "#{$1}\e[49m#{$3}#{$4}" }

    lines.join("\n")
  end

  # ========== Formatting ==========

  def format_bytes(bytes)
    if bytes >= 1_073_741_824 then "%.1f GB" % (bytes.to_f / 1_073_741_824)
    elsif bytes >= 1_048_576 then "%.1f MB" % (bytes.to_f / 1_048_576)
    elsif bytes >= 1024 then "%.1f KB" % (bytes.to_f / 1024)
    else "#{bytes} B"
    end
  end

  def format_number(n)
    n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end
end

# ---------- Logo ----------

CHEWY_LOGO = <<~'ART'
              ▄▄▄▄██▄▄▄▄
         ▄████████████████▄▄
        ▄███████▄  ████  ▄█████▄
       ▄██▀   ▀▀██  ██ ▄██▀▀▀████
      ███████▄   ██ █▀ █▀  ▄██████
     ▄██▀▀   ▀▀▄  ▀      ▄█▀▀ ▀▀███
    ▄██████▀                 ▄█████▄
    ███▀ ▄                      ▀███
    ████▀                      ▀▀███
    ██▀    ▄▄███▄▄▄   ▄▄███▄▄▄    ██
   ██▀   ▄█████████▀  █████████▄   █▄
   ██    ▀▀  ████▀ ▄ ▄▄▀████▀  ▀   ██
  ██ ▄▄       ▀▀ ▄██████          ▄▄█▄
  ████           ▀▀▀▀▀▀▀▄▄        ▀███
  ████ █  ▄              ▀▀█▄   █▄ ███
  █▀███  █▀   ▄▄█▀▀▀██████       █▄██▀
    ███ ██        ▄▄▄▄▄          ████
    ██ ▄█▀          ▀         █▄ ████
   ███▄███ █               ▄  ██▄█▀▀▀█
  ████▀ ██▄█▄  ▄          ██  ████
         ▀███▄ █▄     █ ▄██▀ ███▀
           ▀██ ███▄  █████▀ ▀▀
             █▄█▀▀██▄███▀
              ▀     ▀▀▀▀
ART

def print_logo
  CHEWY_LOGO.each_line do |line|
    puts "\e[1;35m#{line}\e[0m"
  end
end

# ---------- Update Check ----------

def check_for_updates
  uri = URI.parse("https://api.github.com/repos/#{CHEWY_REPO}/releases/latest")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 3
  http.read_timeout = 3
  req = Net::HTTP::Get.new(uri)
  req["Accept"] = "application/vnd.github+json"
  resp = http.request(req)
  return nil unless resp.is_a?(Net::HTTPSuccess)

  data = JSON.parse(resp.body)
  latest = data["tag_name"]&.sub(/^v/, "")
  return nil unless latest

  current_parts = CHEWY_VERSION.split(".").map(&:to_i)
  latest_parts = latest.split(".").map(&:to_i)
  (latest_parts <=> current_parts) > 0 ? latest : nil
rescue
  nil
end

# ---------- Entrypoint ----------

if (new_version = check_for_updates)
  print_logo
  puts "\e[1;35mchewy v#{CHEWY_VERSION}\e[0m -> \e[1;32mv#{new_version}\e[0m available!"
  puts ""
  puts "  brew upgrade Holy-Coders/chewy/chewy"
  puts ""
  print "Continue with current version? [Y/n] "
  answer = $stdin.gets&.strip&.downcase
  exit 0 if answer == "n"
  puts ""
end

Bubbletea.run(Chewy.new, alt_screen: true)
