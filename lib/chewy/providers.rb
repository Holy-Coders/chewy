# frozen_string_literal: true

# ---------- Provider Interface ----------

module Provider
  Capabilities = Struct.new(
    :negative_prompt, :seed, :batch, :img2img, :live_preview,
    :cancel, :model_listing, :lora, :cfg_scale, :sampler,
    :scheduler, :threads, :strength, :width_height, :controlnet,
    :inpainting,
    keyword_init: true
  ) do
    def initialize(**kwargs)
      defaults = { negative_prompt: false, seed: false, batch: false, img2img: false,
                   live_preview: false, cancel: false, model_listing: false, lora: false,
                   cfg_scale: false, sampler: false, scheduler: false, threads: false,
                   strength: false, width_height: true, controlnet: false, inpainting: false }
      super(**defaults.merge(kwargs))
    end
  end

  GenerationRequest = Struct.new(
    :prompt, :negative_prompt, :model, :steps, :cfg_scale,
    :width, :height, :seed, :sampler, :scheduler, :batch,
    :init_image, :strength, :threads, :loras, :output_dir,
    :is_flux, :flux_clip_l, :flux_t5xxl, :flux_vae, :guidance,
    :controlnet_model, :controlnet_image, :controlnet_strength, :controlnet_canny,
    :mask_image,
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
      strength: true, width_height: true, controlnet: true, inpainting: true
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
       "--guidance", (request.guidance || 3.5).to_s,
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
    args += ["--mask", request.mask_image] if request.mask_image
    if request.controlnet_model && request.controlnet_image
      args += ["--control-net", request.controlnet_model, "--control-image", request.controlnet_image]
      args += ["--control-strength", (request.controlnet_strength || 0.9).to_s]
      args << "--canny" if request.controlnet_canny
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
    if all_output.include?("load control net tensors from model loader failed")
      "ControlNet model failed to load — try a different ControlNet model (.pth format required)"
    elsif all_output.include?("get sd version from file failed") || all_output.include?("new_sd_ctx_t failed")
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

    # Normalize model — may come from another provider's selection
    model = "gpt-image-1" unless MODELS.any? { |m| m[:id] == model }

    body = { model: model, prompt: request.prompt, n: n, size: size }

    case model
    when "gpt-image-1"
      body[:quality] = request.steps && request.steps >= 20 ? "high" : "auto"
      body[:output_format] = "png"
    when "dall-e-3"
      body[:quality] = request.steps && request.steps >= 20 ? "hd" : "standard"
      body[:response_format] = "b64_json"
      body[:n] = 1  # dall-e-3 only supports n=1
    when "dall-e-2"
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
      if resp.code == "401"
        error_msg = "Token invalid or missing inference permission — create a new token at huggingface.co/settings/tokens with 'Make calls to Inference Providers' enabled"
      elsif resp.code == "503"
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

# ---------- A1111 (Automatic1111) Provider ----------

class A1111Provider < Provider::Base
  DEFAULT_URL = "http://127.0.0.1:7860".freeze

  def initialize(config = {})
    @base_url = config["base_url"] || DEFAULT_URL
  end

  def id; "a1111"; end
  def display_name; "A1111 (local)"; end
  def provider_type; :api; end

  def capabilities
    Provider::Capabilities.new(
      negative_prompt: true, seed: true, batch: true, img2img: true,
      live_preview: false, cancel: true, model_listing: true, lora: false,
      cfg_scale: true, sampler: true, scheduler: false, threads: false,
      strength: true, width_height: true, controlnet: false, inpainting: true
    )
  end

  def needs_api_key?; false; end
  def api_key_set?; true; end

  def list_models
    uri = URI.parse("#{@base_url}/sdapi/v1/sd-models")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 5; http.read_timeout = 10
    resp = http.request(Net::HTTP::Get.new(uri))
    return [{ id: "default", name: "Default", desc: "Whatever is loaded in A1111" }] unless resp.is_a?(Net::HTTPSuccess)
    models = JSON.parse(resp.body)
    models.map { |m| { id: m["title"], name: m["model_name"] || m["title"], desc: m["filename"] || "" } }
  rescue
    [{ id: "default", name: "Default", desc: "Could not connect to #{@base_url}" }]
  end

  def generate(request, cancelled: -> { false }, &on_event)
    on_event&.call(:status, "Connecting to A1111...")

    endpoint = request.init_image ? "img2img" : "txt2img"
    uri = URI.parse("#{@base_url}/sdapi/v1/#{endpoint}")

    body = {
      prompt: request.prompt,
      negative_prompt: request.negative_prompt || "",
      steps: request.steps || 20,
      cfg_scale: request.cfg_scale || 7.0,
      width: request.width || 512,
      height: request.height || 512,
      seed: request.seed || -1,
      sampler_name: request.sampler || "Euler a",
      batch_size: [request.batch || 1, 1].max,
      save_images: false,
      send_images: true,
    }

    # Model override
    if request.model && request.model != "default"
      body[:override_settings] = { sd_model_checkpoint: request.model }
    end

    # img2img specific
    if request.init_image
      img_data = Base64.strict_encode64(File.binread(request.init_image))
      body[:init_images] = [img_data]
      body[:denoising_strength] = request.strength || 0.75
    end

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 30
    http.read_timeout = 600

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    on_event&.call(:status, "Generating...")
    start_time = Time.now
    resp = http.request(req)
    elapsed = (Time.now - start_time).round(1)

    unless resp.is_a?(Net::HTTPSuccess)
      error_body = JSON.parse(resp.body) rescue {}
      error_msg = error_body["detail"] || "HTTP #{resp.code}: #{resp.message}"
      return Provider::GenerationResult.new(error: error_msg)
    end

    data = JSON.parse(resp.body)
    images = data["images"] || []
    return Provider::GenerationResult.new(error: "No images returned") if images.empty?

    # Parse generation info for seeds
    info = JSON.parse(data["info"]) rescue {}
    seeds = info["all_seeds"] || [info["seed"]] || []

    on_event&.call(:status, "Saving images...")
    FileUtils.mkdir_p(request.output_dir)

    paths = []
    images.each_with_index do |b64, i|
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
      output_path = File.join(request.output_dir, "#{timestamp}_#{i}.png")
      File.binwrite(output_path, Base64.decode64(b64))
      paths << output_path
    end

    return Provider::GenerationResult.new(error: "Failed to save images") if paths.empty?
    Provider::GenerationResult.new(paths: paths, seeds: seeds, elapsed: elapsed)
  rescue Errno::ECONNREFUSED
    Provider::GenerationResult.new(error: "Cannot connect to A1111 at #{@base_url} — is it running with --api?")
  rescue => e
    Provider::GenerationResult.new(error: e.message)
  end

  def cancel(_handle)
    uri = URI.parse("#{@base_url}/sdapi/v1/interrupt")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 5; http.read_timeout = 5
    http.request(Net::HTTP::Post.new(uri))
  rescue
    nil
  end
end
