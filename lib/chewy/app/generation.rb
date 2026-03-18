# frozen_string_literal: true

module Chewy::Generation
  REVEAL_PHASES = 10 # phases 0..9: very blocky → full resolution
  REVEAL_DELAYS = [0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.10, 0.12, 0.14, 0.0].freeze

  SPLASH_PHASES = 6 # phases 0..5: very blocky → clear → dismiss
  SPLASH_PIXELATE = [32, 16, 8, 4, 2, nil].freeze
  SPLASH_DELAYS = [0.3, 0.25, 0.2, 0.15, 0.8, 0.0].freeze # linger at full res before dismiss

  HF_TOKEN_PATHS = [
    File.expand_path("~/.cache/huggingface/token"),
    File.expand_path("~/.huggingface/token"),
  ].freeze

  private

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

  # Set a toast status message that auto-dismisses after 3 seconds.
  # Returns a tick command that should be returned from update.
  def set_status_toast(msg)
    @status_message = msg
    @status_generation += 1
    gen = @status_generation
    Bubbletea.tick(3.0) { StatusDismissMessage.new(generation: gen) }
  end

  # Set an error message that auto-dismisses after 5 seconds.
  # Returns a tick command that should be returned from update.
  def set_error_toast(msg)
    @error_message = msg
    @error_generation += 1
    gen = @error_generation
    Bubbletea.tick(5.0) { ErrorDismissMessage.new(generation: gen) }
  end

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
        return [self, set_status_toast("FLUX companion files ready")]
      else
        return [self, set_error_toast("Some downloads failed: #{@companion_errors.join(', ')}")]
      end
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

  def start_generation
    prompt_text = @prompt_input.value.strip
    negative_text = @negative_input.value.strip

    if prompt_text.empty?
      return [self, set_error_toast("Prompt cannot be empty")]
    end

    # Warn about Schnell + img2img — Schnell is distilled for txt2img and img2img results are poor
    if @init_image_path && @provider.provider_type == :local && @selected_model_path
      name = File.basename(@selected_model_path).downcase
      if name.include?("schnell")
        return [self, set_error_toast("Schnell models are poor at img2img — use FLUX Dev, SD 1.5, or SDXL instead")]
      end
    end

    # ControlNet is not supported with FLUX models
    if @controlnet_model_path && @provider.provider_type == :local && @selected_model_path
      if flux_model?(@selected_model_path)
        return [self, set_error_toast("ControlNet is not supported with FLUX models — use SD 1.5, SD 2.x, or SDXL")]
      end
    end

    # Warn if selected LoRAs appear incompatible with the model architecture
    if @selected_loras.any? && @provider.provider_type == :local && @selected_model_path
      model_type = detect_model_type(@selected_model_path)
      if model_type
        mismatch = @selected_loras.find { |l| !lora_compatible?(l[:name], l[:path], model_type) }
        if mismatch
          lora_type = detect_lora_type(mismatch[:name], mismatch[:path])
          lora_label = lora_type || "unknown type"
          return [self, set_error_toast("LoRA \"#{mismatch[:name]}\" (#{lora_label}) may not work with #{model_type} model")]
        end
      end
    end

    # Local provider needs a model file; remote providers use @remote_model_id
    if @provider.provider_type == :local
      unless @selected_model_path
        return [self, set_error_toast("No model selected")]
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
      controlnet_model: @controlnet_model_path,
      controlnet_image: @controlnet_image_path,
      controlnet_strength: @controlnet_strength,
      controlnet_canny: @controlnet_canny,
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
    if @controlnet_model_path
      sidecar_base["controlnet_model"] = @controlnet_model_path
      sidecar_base["controlnet_image"] = @controlnet_image_path
      sidecar_base["controlnet_strength"] = @controlnet_strength
      sidecar_base["controlnet_canny"] = @controlnet_canny
    end

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
end
