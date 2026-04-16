# frozen_string_literal: true

class Chewy
  module Models
    private

    def scan_models
      Dir.glob(File.join(@models_dir, "**", "*.part")).each { |f| File.delete(f) rescue nil }

      companion_names = FLUX_COMPANION_FILES.values.map { |v| v[:filename] } +
                        WAN_COMPANION_FILES.values.map { |v| v[:filename] } +
                        Z_IMAGE_COMPANION_FILES.values.map { |v| v[:filename] } +
                        QWEN_IMAGE_COMPANION_FILES.values.map { |v| v[:filename] } +
                        FLUX2_COMPANION_FILES.values.flat_map { |h| h.values.map { |v| v[:filename] } }.uniq
      ext_glob = "*.{safetensors,gguf,ckpt}"

      # Scan primary dir + any extra app directories that exist
      dirs = [@models_dir] + EXTRA_MODEL_DIRS.select { |d| File.directory?(d) }
      files = dirs.flat_map { |d| Dir.glob(File.join(d, "**", ext_glob)) }
        .uniq
        .reject { |f| companion_names.include?(File.basename(f)) }
        .reject { |f| File.basename(f) =~ /\blora\b/i }   # LoRA weights, not diffusion models
        .reject { |f| File.basename(f) =~ /\bcontrol\b/i } # ControlNet models, not diffusion models
        .reject { |f| File.size(f) < 100_000_000 }         # too small to be a diffusion model

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
          name = File.basename(f)
          prefix = @pinned_models.include?(f) ? "* " : "  "
          source = model_source_tag(f)
          type_tag = model_type_tag(f)
          family = model_family_for(detect_model_type(f))
          family_tag = family ? " [#{family}]" : ""
          size_str = File.exist?(f) ? format_bytes(File.size(f)) : ""
          { title: "#{prefix}#{name}", description: "#{size_str} #{type_tag}#{family_tag}#{source}".strip }
        end
      end

      @model_list = Bubbles::List.new(items, width: @width - 12, height: [@height - 10, 6].max)
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

    def scan_api_models
      models = @provider.list_models
      @api_model_entries = models

      items = if models.empty?
        [{ title: "No models available", description: "" }]
      else
        models.map do |m|
          { title: "  #{m[:name]}", description: m[:desc] || "" }
        end
      end

      @model_list = Bubbles::List.new(items, width: @width - 12, height: [@height - 10, 6].max)
      @model_list.show_title = false
      @model_list.show_status_bar = false
      @model_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      @model_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)

      # Select current model
      if models.any?
        cur = models.index { |m| m[:id] == @remote_model_id } || 0
        @model_list.select(cur)
      end
    end

    def model_type_tag(path)
      # Use cached type from previous validation if available
      if @model_types[path]
        return " | #{@model_types[path]}"
      end
      # Guess from filename
      name = File.basename(path).downcase
      type = if name.include?("wan2") || name.include?("wan-") || name.include?("wan_")
        "Wan"
      elsif name.match?(/\bz[-_]?image/)
        "Z-Image"
      elsif name.match?(/qwen[-_]?image/) && !name.include?("vae") && !name.include?("instruct")
        "Qwen-Image"
      elsif name.match?(/flux[-_]?2|klein/)
        "FLUX2"
      elsif name.include?("chroma")
        "Chroma"
      elsif name.include?("flux")
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
              type = if output.include?("Version: Wan") || output.include?("Version: wan")
                "Wan"
              elsif output.include?("Version: Flux 2") || output.include?("Version: FLUX.2")
                "FLUX2"
              elsif output.include?("Version: Flux")
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
        filter_loras # re-filter LoRAs now that we know the model type
      end
      [self, nil]
    end

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

    def detect_model_type(path)
      return nil unless path
      # Prefer cached validated type
      return @model_types[path] if @model_types[path]
      # Guess from filename
      name = File.basename(path).downcase
      if name.include?("wan2") || name.include?("wan-") || name.include?("wan_")
        "Wan"
      elsif name.match?(/\bz[-_]?image/)
        "Z-Image"
      elsif name.match?(/qwen[-_]?image/) && !name.include?("vae") && !name.include?("instruct")
        "Qwen-Image"
      elsif name.match?(/flux[-_]?2|klein/)
        "FLUX2"
      elsif name.include?("chroma")
        "Chroma"
      elsif name.include?("flux")
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
    end

    def model_family_for(model_type)
      return nil unless model_type
      MODEL_FAMILY_LOOKUP[model_type.downcase] || model_type
    end

    def current_model_family
      return nil unless @selected_model_path
      model_type = detect_model_type(@selected_model_path)
      model_family_for(model_type)
    end

    def flux_model?(path)
      return false unless path
      basename = File.basename(path).downcase
      basename.include?("flux") && !flux2_model?(path)
    end

    def kontext_model?(path)
      return false unless path
      basename = File.basename(path).downcase
      basename.include?("kontext")
    end

    def chroma_model?(path)
      return false unless path
      basename = File.basename(path).downcase
      basename.include?("chroma")
    end

    def z_image_model?(path)
      return false unless path
      basename = File.basename(path).downcase
      basename.match?(/\bz[-_]?image/)
    end

    def qwen_image_model?(path)
      return false unless path
      basename = File.basename(path).downcase
      basename.match?(/qwen[-_]?image/) && !basename.include?("vae") && !basename.include?("instruct")
    end

    def qwen_image_companion_path(key)
      info = QWEN_IMAGE_COMPANION_FILES[key]
      return nil unless info
      File.join(@models_dir, info[:filename])
    end

    def qwen_image_companions_present?
      QWEN_IMAGE_COMPANION_FILES.all? { |key, _| File.exist?(qwen_image_companion_path(key)) }
    end

    def missing_qwen_image_companions
      QWEN_IMAGE_COMPANION_FILES.select { |key, _| !File.exist?(qwen_image_companion_path(key)) }
    end

    def download_qwen_image_companions
      missing = missing_qwen_image_companions
      return [self, nil] if missing.empty?

      hf_token = resolve_hf_token
      unless hf_token
        @hf_token_pending_action = :qwen_image_companions
        return open_overlay(:hf_token)
      end

      @companion_downloading = true
      @companion_remaining = missing.size
      @companion_errors = []
      @companion_current_file = ""
      @companion_dest = nil

      queue = missing.to_a
      start_next_companion_download(queue, hf_token)
    end

    def z_image_companion_path(key)
      info = Z_IMAGE_COMPANION_FILES[key]
      return nil unless info
      File.join(@models_dir, info[:filename])
    end

    def z_image_companions_present?
      Z_IMAGE_COMPANION_FILES.all? { |key, _| File.exist?(z_image_companion_path(key)) }
    end

    def missing_z_image_companions
      Z_IMAGE_COMPANION_FILES.select { |key, _| !File.exist?(z_image_companion_path(key)) }
    end

    def download_z_image_companions
      missing = missing_z_image_companions
      return [self, nil] if missing.empty?

      hf_token = resolve_hf_token
      unless hf_token
        @hf_token_pending_action = :z_image_companions
        return open_overlay(:hf_token)
      end

      @companion_downloading = true
      @companion_remaining = missing.size
      @companion_errors = []
      @companion_current_file = ""
      @companion_dest = nil

      queue = missing.to_a
      start_next_companion_download(queue, hf_token)
    end

    # Look for a TAESD decoder matching the given model's architecture.
    # Returns nil if none present — caller falls back to --preview proj.
    def taesd_path_for(path)
      return nil unless path
      arch = if flux_model?(path) || kontext_model?(path)
        :flux
      elsif detect_model_type(path) == "SDXL"
        :sdxl
      elsif flux2_model?(path) || wan_model?(path)
        return nil  # sd.cpp TAESD doesn't cover these yet
      else
        :sd
      end
      globs = TAESD_FILES[arch] || []
      globs.each do |g|
        match = Dir.glob(File.join(@models_dir, g)).first
        return match if match
      end
      nil
    end

    def flux2_model?(path)
      return false unless path
      basename = File.basename(path).downcase
      basename.match?(/flux[-_]?2|klein/)
    end

    # FLUX.2 Dev supports image editing via sd.cpp's -r flag; Klein is text-to-image only.
    def flux2_dev_model?(path)
      return false unless flux2_model?(path)
      File.basename(path).downcase.include?("dev")
    end

    # FLUX.2 Dev uses Mistral-Small; Klein 4B/9B use Qwen3-4B/8B respectively.
    def flux2_variant(path)
      return :_dev if flux2_dev_model?(path)
      basename = File.basename(path.to_s).downcase
      basename.match?(/(?:^|[^0-9])4b(?:[^0-9]|$)/) ? :_4b : :_9b
    end

    def flux2_companions_for(path)
      FLUX2_COMPANION_FILES[flux2_variant(path)] || {}
    end

    def flux2_companion_path(key, path = @selected_model_path)
      info = flux2_companions_for(path)[key]
      return nil unless info
      File.join(@models_dir, info[:filename])
    end

    def flux2_companions_present?(path = @selected_model_path)
      flux2_companions_for(path).all? { |key, _| File.exist?(flux2_companion_path(key, path)) }
    end

    def missing_flux2_companions(path = @selected_model_path)
      flux2_companions_for(path).select { |key, _| !File.exist?(flux2_companion_path(key, path)) }
    end

    def download_flux2_companions
      missing = missing_flux2_companions
      return [self, nil] if missing.empty?

      hf_token = resolve_hf_token
      unless hf_token
        @hf_token_pending_action = :flux2_companions
        return open_overlay(:hf_token)
      end

      @companion_downloading = true
      @companion_remaining = missing.size
      @companion_errors = []
      @companion_current_file = ""
      @companion_dest = nil

      queue = missing.to_a
      start_next_companion_download(queue, hf_token)
    end

    def wan_model?(path)
      return false unless path
      basename = File.basename(path).downcase
      basename.include?("wan2") || basename.include?("wan-") || basename.include?("wan_")
    end

    def wan_companion_path(key)
      info = WAN_COMPANION_FILES[key]
      return nil unless info
      File.join(@models_dir, info[:filename])
    end

    def wan_companions_present?
      WAN_COMPANION_FILES.all? { |key, _| File.exist?(wan_companion_path(key)) }
    end

    def missing_wan_companions
      WAN_COMPANION_FILES.select { |key, _| !File.exist?(wan_companion_path(key)) }
    end

    def download_wan_companions
      missing = missing_wan_companions
      return [self, nil] if missing.empty?

      hf_token = resolve_hf_token
      unless hf_token
        @hf_token_pending_action = :wan_companions
        return open_overlay(:hf_token)
      end

      @companion_downloading = true
      @companion_remaining = missing.size
      @companion_errors = []
      @companion_current_file = ""
      @companion_dest = nil

      queue = missing.to_a
      start_next_companion_download(queue, hf_token)
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
      File.chmod(0600, HF_TOKEN_PATHS.first)
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
          return [self, set_status_toast("Companion files ready")]
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
        # First get file size via HEAD request (grab last content-length after redirects)
        head_args = ["curl", "-sI", "-L", url]
        head_args += ["-H", "Authorization: Bearer #{hf_token}"] if hf_token && !hf_token.empty?
        size_out, _ = Open3.capture2(*head_args)
        content_length = size_out.scan(/content-length:\s*(\d+)/i).flatten.last&.to_i || 0
        @companion_download_size = content_length

        # Download — try without auth first (public repos), fall back to auth if needed
        curl_base = ["curl", "-fL", "-o", part, "-sS",
                     "-C", "-", "--retry", "3", "--retry-delay", "2", "--retry-all-errors"]
        _out, err, st = Open3.capture3(*curl_base, url)
        unless st.success?
          # Retry with auth token for gated repos
          File.delete(part) if File.exist?(part)
          _out, err, st = Open3.capture3(*curl_base, "-H", "Authorization: Bearer #{hf_token}", url)
        end
        if st.success? && File.exist?(part) && File.size(part) > 0
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

    def select_model_by_type(type)
      return unless File.directory?(@models_dir)
      pattern = case type
      when "wan" then /wan2|wan[_\-]/i
      when "flux" then /flux/i
      when "sdxl" then /sdxl|sd_xl/i
      when "sd3" then /sd3/i
      when "sd" then /sd[_\-]?1|v1[_\-]|stable.diffusion.*1/i
      end
      return unless pattern

      # Prefer pinned models, then recent, then any match
      # Use the already-scanned model list to avoid matching ControlNet/LoRA/companion files
      candidates = @model_paths || []
      match = (@pinned_models || []).find { |p| File.basename(p) =~ pattern && File.exist?(p) }
      match ||= (@recent_models || []).find { |p| File.basename(p) =~ pattern && File.exist?(p) }
      match ||= candidates.find { |p| File.basename(p) =~ pattern }

      if match
        @selected_model_path = match
        @preview_cache = nil
      end
    end

    def api_model_type(model)
      return model[:type].to_s.upcase if model[:type]
      name = (model[:name] || model[:id] || "").downcase
      if name.include?("flux")
        "FLUX"
      elsif name.include?("sdxl") || name.include?("sd xl")
        "SDXL"
      elsif name.include?("sd 3") || name.include?("sd3")
        "SD3"
      end
    end
  end
end
