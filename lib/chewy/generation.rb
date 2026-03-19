# frozen_string_literal: true

class Chewy
  module Generation
    private

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

      if @mask_image_path && !@init_image_path
        return [self, set_error_toast("Mask requires an init image — press ^b to browse")]
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
        guidance: is_flux ? @params[:guidance] : nil,
        flux_clip_l: is_flux ? flux_companion_path("clip_l") : nil,
        flux_t5xxl: is_flux ? flux_companion_path("t5xxl") : nil,
        flux_vae: is_flux ? flux_companion_path("vae") : nil,
        controlnet_model: @controlnet_model_path,
        controlnet_image: @controlnet_image_path,
        controlnet_strength: @controlnet_strength,
        controlnet_canny: @controlnet_canny,
        mask_image: @mask_image_path,
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
      sidecar_base["mask_image"] = @mask_image_path if @mask_image_path

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

    def generate_quick_mask
      unless @init_image_path
        return [self, set_error_toast("Set an init image first (^b)")]
      end
      mask_path = File.join(@output_dir, ".mask_#{Time.now.strftime('%Y%m%d_%H%M%S')}.png")
      FileUtils.mkdir_p(@output_dir)
      generate_center_preserve_mask(@params[:width], @params[:height], mask_path)
      @mask_image_path = mask_path
      [self, set_status_toast("Auto-mask generated (center preserved)")]
    end

    def open_mask_painter
      unless @init_image_path
        return [self, set_error_toast("Set an init image first (^b)")]
      end
      # Build the paint grid from the init image
      paint_cols = [(@width * 0.4).to_i, 30].max
      paint_rows = [(@height - 8), 10].max
      @mask_paint_grid_colors = build_paint_grid(@init_image_path, paint_cols, paint_rows)
      unless @mask_paint_grid_colors
        return [self, set_error_toast("Failed to load image for mask painting")]
      end
      @mask_paint_grid = Array.new(paint_rows) { Array.new(paint_cols, false) }
      @mask_paint_cols = paint_cols
      @mask_paint_rows = paint_rows
      @mask_paint_brush = :paint  # :paint or :erase
      @overlay = :mask_painter
      [self, nil]
    end

    def load_prompt_history_from_disk
      dir = File.expand_path(ENV["CHEWY_OUTPUT_DIR"] || @config["output_dir"] || "~/.config/chewy/outputs")
      return [] unless File.directory?(dir)

      jsons = Dir.glob(File.join(dir, "*.json")).sort # oldest first
      prompts = jsons.filter_map do |f|
        data = JSON.parse(File.read(f)) rescue next
        p = data["prompt"]&.strip
        p unless p.nil? || p.empty?
      end
      prompts.uniq.last(100)
    end

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
  end
end
