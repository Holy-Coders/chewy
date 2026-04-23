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
        if flux2_model?(@selected_model_path) && !flux2_dev_model?(@selected_model_path)
          return [self, set_error_toast("FLUX.2 Klein is text-to-image only — use FLUX.2 Dev for image editing")]
        end
        if z_image_model?(@selected_model_path)
          return [self, set_error_toast("Z-Image is text-to-image only in chewy — remove the init image")]
        end
        if qwen_image_model?(@selected_model_path)
          return [self, set_error_toast("Qwen-Image is text-to-image only in chewy — remove the init image")]
        end
      end

      # Kontext requires a reference image
      if @provider.provider_type == :local && @selected_model_path && kontext_model?(@selected_model_path) && !@init_image_path
        return [self, set_error_toast("FLUX.1 Kontext requires a reference image — press ^b to select one")]
      end

      if @provider.provider_type == :local && @selected_model_path && wan_model?(@selected_model_path)
        if @init_image_path && wan_t2v_model?(@selected_model_path)
          return [self, set_error_toast("Selected Wan model is text-to-video only — clear the init image or install a Wan I2V model")]
        end
        if !@init_image_path && wan_i2v_model?(@selected_model_path)
          return [self, set_error_toast("Selected Wan model needs an init image — press ^b to pick a starting frame")]
        end
      end

      # ControlNet is not supported with FLUX or Wan models
      if @controlnet_model_path && @provider.provider_type == :local && @selected_model_path
        if flux_model?(@selected_model_path) || flux2_model?(@selected_model_path)
          return [self, set_error_toast("ControlNet is not supported with FLUX models — use SD 1.5, SD 2.x, or SDXL")]
        end
        if wan_model?(@selected_model_path)
          return [self, set_error_toast("ControlNet is not supported with Wan video models")]
        end
      end

      if @mask_image_path && !@init_image_path
        return [self, set_error_toast("Mask requires an init image — press ^b to browse")]
      end

      # Memory warning for local models — warn but allow user to proceed
      if @provider.provider_type == :local && @selected_model_path && !@confirm_low_memory
        available_mem = estimate_available_memory
        estimated_need = estimate_runtime_memory_need(@selected_model_path)
        if available_mem > 0 && estimated_need > available_mem
          need_gb = (estimated_need / 1_073_741_824.0).round(1)
          avail_gb = (available_mem / 1_073_741_824.0).round(1)
          @confirm_low_memory = true
          @low_memory_warning = if wan_model?(@selected_model_path)
            "#{File.basename(@selected_model_path)} needs ~#{need_gb}GB for #{@params[:video_frames]} frames at #{@params[:width]}x#{@params[:height]}, but only #{avail_gb}GB is available"
          else
            "#{File.basename(@selected_model_path)} needs ~#{need_gb}GB but only #{avail_gb}GB is available"
          end
          return [self, nil]
        end
      end
      @confirm_low_memory = false
      @low_memory_warning = nil

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
        if (flux_model?(@selected_model_path) || chroma_model?(@selected_model_path)) && !flux_companions_present?
          return download_flux_companions
        end
        if flux2_model?(@selected_model_path) && !flux2_companions_present?
          return download_flux2_companions
        end
        if z_image_model?(@selected_model_path) && !z_image_companions_present?
          return download_z_image_companions
        end
        if qwen_image_model?(@selected_model_path) && !qwen_image_companions_present?
          return download_qwen_image_companions
        end
        if wan_model?(@selected_model_path) && !wan_companions_present?
          return download_wan_companions
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
      @gen_video_frame = nil
      @gen_video_frame_total = nil
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

      # Dynamic thread count based on current system load
      if @provider.provider_type == :local
        @params[:threads] = safe_thread_count
        @params[:threads] = [@params[:threads], 4].min if wan_model?(@selected_model_path)
      end

      # Build provider-agnostic request
      model = if @provider.provider_type == :local
        @selected_model_path
      else
        @remote_model_id || @provider.list_models.first&.dig(:id)
      end
      is_flux = @provider.provider_type == :local && @selected_model_path && flux_model?(@selected_model_path)
      is_flux2 = @provider.provider_type == :local && @selected_model_path && flux2_model?(@selected_model_path)
      is_kontext = @provider.provider_type == :local && @selected_model_path && kontext_model?(@selected_model_path)
      is_chroma = @provider.provider_type == :local && @selected_model_path && chroma_model?(@selected_model_path)
      is_z_image = @provider.provider_type == :local && @selected_model_path && z_image_model?(@selected_model_path)
      is_qwen_image = @provider.provider_type == :local && @selected_model_path && qwen_image_model?(@selected_model_path)
      is_wan = @provider.provider_type == :local && @selected_model_path && wan_model?(@selected_model_path)

      if is_wan
        @gen_status = "Video generation is experimental — works best with dedicated GPU hardware"
      end

      request = Provider::GenerationRequest.new(
        prompt: full_prompt, negative_prompt: negative_text,
        model: model, steps: @params[:steps], cfg_scale: @params[:cfg_scale],
        width: @params[:width], height: @params[:height],
        seed: @params[:seed], sampler: @sampler, scheduler: @scheduler,
        batch: is_wan ? 1 : @params[:batch], init_image: @init_image_path,
        strength: @params[:strength], threads: @params[:threads],
        loras: @selected_loras, output_dir: @output_dir,
        is_flux: is_flux,
        guidance: is_flux ? @params[:guidance] : nil,
        flux_clip_l: is_flux ? flux_companion_path("clip_l") : nil,
        flux_t5xxl: is_flux ? flux_companion_path("t5xxl") : nil,
        flux_vae: is_flux ? flux_companion_path("vae") : nil,
        is_flux2: is_flux2,
        flux2_llm: is_flux2 ? flux2_companion_path("llm") : nil,
        flux2_vae: is_flux2 ? flux2_companion_path("vae") : nil,
        is_kontext: is_kontext,
        ref_image: (is_kontext || (is_flux2 && flux2_dev_model?(@selected_model_path) && @init_image_path)) ? @init_image_path : nil,
        is_chroma: is_chroma,
        chroma_t5xxl: is_chroma ? flux_companion_path("t5xxl") : nil,
        chroma_vae: is_chroma ? flux_companion_path("vae") : nil,
        is_z_image: is_z_image,
        z_image_llm: is_z_image ? z_image_companion_path("llm") : nil,
        z_image_vae: is_z_image ? z_image_companion_path("vae") : nil,
        is_qwen_image: is_qwen_image,
        qwen_image_llm: is_qwen_image ? qwen_image_companion_path("llm") : nil,
        qwen_image_vae: is_qwen_image ? qwen_image_companion_path("vae") : nil,
        taesd_path: @provider.provider_type == :local && @selected_model_path ? taesd_path_for(@selected_model_path) : nil,
        controlnet_model: is_wan ? nil : @controlnet_model_path,
        controlnet_image: is_wan ? nil : @controlnet_image_path,
        controlnet_strength: @controlnet_strength,
        controlnet_canny: @controlnet_canny,
        mask_image: is_wan ? nil : @mask_image_path,
        video_mode: is_wan,
        video_frames: is_wan ? @params[:video_frames] : nil,
        fps: is_wan ? @params[:fps] : nil,
        is_wan: is_wan,
        wan_t5xxl: is_wan ? wan_companion_path("t5xxl") : nil,
        wan_clip_vision: is_wan ? wan_companion_path("clip_vision") : nil,
        wan_vae: is_wan ? wan_companion_path("vae") : nil,
      )

      sidecar_base = {
        "prompt" => prompt_text, "negative_prompt" => negative_text,
        "model" => model, "steps" => @params[:steps], "cfg_scale" => @params[:cfg_scale],
        "width" => @params[:width], "height" => @params[:height],
        "sampler" => @sampler, "scheduler" => @scheduler,
        "provider" => @provider.id, "provider_name" => @provider.display_name,
      }
      if @provider.provider_type == :local
        sidecar_base["model_type"] = is_wan ? "wan" : (is_flux2 ? "flux2" : (is_flux ? "flux" : "sd"))
      end
      if is_wan
        sidecar_base["type"] = "video"
        sidecar_base["video_frames"] = @params[:video_frames]
        sidecar_base["fps"] = @params[:fps]
        sidecar_base["duration"] = (@params[:video_frames].to_f / (@params[:fps] || 24)).round(2)
      end
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
          when :video_frame_progress
            @gen_video_frame = data[:frame]; @gen_video_frame_total = data[:total]
          end
        end

        @gen_pid = nil
        @gen_preview_path = nil; @gen_preview_mtime = nil; @gen_preview_cache = nil

        if @gen_cancelled
          @gen_cancelled = false
          GenerationErrorMessage.new(error: "Cancelled", stderr_output: "")
        elsif result.error
          GenerationErrorMessage.new(error: result.error, stderr_output: "")
        elsif result.video_frame_paths&.any?
          # Video generation completed
          @last_seed = result.seeds&.last
          elapsed = (Time.now - total_start).round(1)
          # Write sidecar for the video
          sidecar_path = File.join(result.video_frames_dir, "video.json")
          unless File.exist?(sidecar_path)
            sidecar = sidecar_base.merge(
              "seed" => result.seeds&.first,
              "timestamp" => Time.now.iso8601,
              "generation_time_seconds" => result.elapsed,
              "frame_count" => result.video_frame_paths.length,
            )
            File.write(sidecar_path, JSON.pretty_generate(sidecar))
          end
          VideoGenerationDoneMessage.new(
            frames_dir: result.video_frames_dir,
            frame_paths: result.video_frame_paths,
            elapsed: elapsed,
            stderr_output: ""
          )
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

    def estimate_runtime_memory_need(path)
      model_size = File.size(path) rescue 0
      return 0 if model_size <= 0

      if wan_model?(path)
        frame_factor = [(@params[:video_frames] || 17).to_f / 17.0, 1.0].max
        pixel_count = (@params[:width] || 384).to_i * (@params[:height] || 672).to_i
        base_pixels = 384 * 672
        resolution_factor = Math.sqrt([pixel_count.to_f / base_pixels, 1.0].max)
        i2v_factor = @init_image_path ? 1.25 : 1.0
        return (model_size * 2.0 * frame_factor * resolution_factor * i2v_factor).to_i
      end

      multiplier = if flux2_model?(path) || flux_model?(path) || chroma_model?(path) || z_image_model?(path) || qwen_image_model?(path)
        1.8
      elsif detect_model_type(path) == "SDXL"
        1.7
      else
        1.5
      end
      (model_size * multiplier).to_i
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

      jsons = Dir.glob(File.join(dir, "*.json")).sort_by { |f| File.mtime(f) rescue Time.at(0) }.last(100)
      prompts = jsons.filter_map do |f|
        data = JSON.parse(File.read(f)) rescue next
        p = data["prompt"]&.strip
        p unless p.nil? || p.empty?
      end
      prompts.uniq.last(100)
    end

    # ---------- Generation queue ----------

    # Snapshot the current prompt/params and append to the queue.
    # When the active generation finishes, dequeue_next_generation picks it up.
    def enqueue_current
      prompt = @prompt_input.value.strip
      return [self, set_error_toast("Prompt cannot be empty")] if prompt.empty?
      snapshot = {
        prompt: prompt,
        negative: @negative_input.value,
        params: @params.dup,
        sampler: @sampler,
        scheduler: @scheduler,
        model: @selected_model_path,
        init_image: @init_image_path,
        mask_image: @mask_image_path,
        loras: @selected_loras.dup,
      }
      @generation_queue << snapshot
      [self, set_status_toast("Queued (#{@generation_queue.length} waiting)")]
    end

    def dequeue_next_generation
      return [self, nil] if @generation_queue.empty?
      snap = @generation_queue.shift
      @prompt_input.value = snap[:prompt]
      @negative_input.value = snap[:negative] || ""
      @params = snap[:params] if snap[:params]
      @sampler = snap[:sampler] if snap[:sampler]
      @scheduler = snap[:scheduler] if snap[:scheduler]
      @selected_model_path = snap[:model] if snap[:model]
      @init_image_path = snap[:init_image]
      @mask_image_path = snap[:mask_image]
      @selected_loras = snap[:loras] || []
      start_generation
    end

    def clear_generation_queue
      count = @generation_queue.length
      @generation_queue.clear
      [self, set_status_toast("Cleared #{count} queued generation#{count == 1 ? "" : "s"}")]
    end

    # Seed sweep — enqueue N variants of the current prompt with random seeds.
    # Builds on the generation queue so results stream into the gallery as each finishes.
    def seed_sweep(n = 4)
      prompt = @prompt_input.value.strip
      return [self, set_error_toast("Prompt cannot be empty")] if prompt.empty?
      seeds = Array.new(n) { rand(0..2**31 - 1) }
      # First seed becomes the active generation; the rest go in the queue
      @params[:seed] = seeds.first
      seeds.drop(1).each do |s|
        params = @params.dup
        params[:seed] = s
        @generation_queue << {
          prompt: prompt,
          negative: @negative_input.value,
          params: params,
          sampler: @sampler,
          scheduler: @scheduler,
          model: @selected_model_path,
          init_image: @init_image_path,
          mask_image: @mask_image_path,
          loras: @selected_loras.dup,
        }
      end
      _self, cmd = start_generation
      [self, cmd || set_status_toast("Sweep: #{n} seeds queued")]
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
