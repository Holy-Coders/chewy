# frozen_string_literal: true

class Chewy
  module Overlays
    private

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
      clear_kitty_images if @kitty_graphics
      @overlay = name
      @error_message = nil
      cmd = nil

      case name
      when :models then @provider.provider_type == :api ? scan_api_models : scan_models
      when :lora then scan_loras
      when :api_key then @api_key_input.focus; @api_key_input.value = ""
      when :hf_token then @hf_token_input.focus
      when :tokens
        @tokens_hf_input.value = resolve_hf_token.to_s
        @tokens_civitai_input.value = resolve_civitai_token.to_s
        @tokens_field = 0
        @tokens_hf_input.focus; @tokens_civitai_input.blur
      when :preset then nil
      when :theme then @theme_index = THEME_NAMES.index(Theme.current_name) || 0; @theme_original = Theme.current_name
      when :provider then @provider_index = @providers.index(@provider) || 0
      when :gallery
        build_gallery
        _model, cmd = gallery_load_thumb_async unless @gallery_preview_ready
      when :file_picker
        scan_file_picker_dir
        _model, cmd = kickoff_file_picker_preview
      end
      [self, cmd]
    end

    def close_overlay
      @hf_token_input.blur if @overlay == :hf_token
      @api_key_input.blur if @overlay == :api_key
      if @overlay == :tokens
        @tokens_hf_input.blur; @tokens_civitai_input.blur
      end
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

    def handle_overlay_key(message)
      key = message.to_s
      return [self, Bubbletea.quit] if key == "ctrl+c"

      case @overlay
      when :models   then handle_models_panel_key(message)
      when :download then handle_download_key(message)
      when :lora     then handle_lora_panel_key(message)
      when :lora_download then handle_lora_download_key(message)
      when :cn_download then handle_cn_download_key(message)
      when :help     then handle_help_key(message)
      when :preset   then handle_preset_panel_key(message)
      when :theme    then handle_theme_key(message)
      when :provider then handle_provider_key(message)
      when :api_key  then handle_api_key_key(message)
      when :hf_token then handle_hf_token_key(message)
      when :tokens   then handle_tokens_key(message)
      when :gallery  then handle_gallery_key(message)
      when :fullscreen_image then handle_fullscreen_key(message)
      when :file_picker then handle_file_picker_key(message)
      when :mask_painter then handle_mask_painter_key(message)
      when :starter_pack then handle_starter_pack_key(message)
      when :video_player then handle_video_player_key(message)
      when :prompt_search then handle_prompt_search_key(message)
      else [self, nil]
      end
    end

    def open_prompt_search
      @prompt_search_input.value = ""
      @prompt_search_input.focus
      @prompt_search_matches = @prompt_history.reverse
      @prompt_search_index = 0
      @overlay = :prompt_search
      [self, nil]
    end

    def fuzzy_match_prompts(query)
      return @prompt_history.reverse if query.empty?
      q = query.downcase
      scored = @prompt_history.filter_map do |p|
        next nil unless p.downcase.include?(q) || q.chars.all? { |c| p.downcase.include?(c) }
        score = p.downcase.include?(q) ? 1000 - p.length : 100 - p.length
        [score, p]
      end
      scored.sort_by { |s, _| -s }.map { |_, p| p }
    end

    def handle_prompt_search_key(message)
      key = message.to_s
      case key
      when "esc", "ctrl+g"
        @prompt_search_input.blur
        return close_overlay
      when "enter"
        chosen = @prompt_search_matches[@prompt_search_index]
        if chosen
          @prompt_input.value = chosen
          @history_index = -1
        end
        @prompt_search_input.blur
        return close_overlay
      when "up", "ctrl+p"
        @prompt_search_index = [@prompt_search_index - 1, 0].max
        return [self, nil]
      when "down", "ctrl+n"
        @prompt_search_index = [@prompt_search_index + 1, [@prompt_search_matches.length - 1, 0].max].min
        return [self, nil]
      when "ctrl+v"
        return paste_text_into(@prompt_search_input)
      end
      @prompt_search_input, cmd = @prompt_search_input.update(message)
      @prompt_search_matches = fuzzy_match_prompts(@prompt_search_input.value.strip)
      @prompt_search_index = 0
      [self, cmd]
    end

    def handle_models_panel_key(message)
      key = message.to_s

      # Handle best-settings confirmation popup
      if @confirm_apply_best_settings
        case key
        when "y"
          source = @pending_best_settings_img2img ? IMG2IMG_BEST_SETTINGS : MODEL_BEST_SETTINGS
          settings = source[@pending_best_settings_type]
          cmd = settings ? load_preset({ data: settings }) : nil
          @confirm_apply_best_settings = false
          @pending_best_settings_type = nil
          @pending_best_settings_img2img = false
          close_overlay
          return [self, cmd]
        else
          @confirm_apply_best_settings = false
          @pending_best_settings_type = nil
          @pending_best_settings_img2img = false
          return close_overlay
        end
      end

      return close_overlay if key == "esc" || key == "q"
      return [self, nil] unless @model_list

      if @provider.provider_type == :api
        return handle_api_model_select(key, message)
      end

      case key
      when "enter"
        idx = @model_list.selected_index rescue 0
        if @model_paths&.any? && idx < @model_paths.length
          @selected_model_path = @model_paths[idx]
          @preview_cache = nil # invalidate preview when model changes
          filter_loras # re-filter LoRAs for new model family
          update_param_keys # refresh param list (e.g. guidance for FLUX)
          save_config
          # Validate model in background if we don't know its type yet
          validate_cmd = nil
          unless @model_types[@selected_model_path]
            validate_cmd = validate_model_cmd(@selected_model_path)
          end
          # Offer best settings if we can detect the model type
          model_type = detect_model_type(@selected_model_path)
          if model_type && MODEL_BEST_SETTINGS[model_type]
            @confirm_apply_best_settings = true
            @pending_best_settings_type = model_type
            return [self, validate_cmd]
          end
          if validate_cmd
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

    def handle_api_model_select(key, message)
      models = @api_model_entries || @provider.list_models
      case key
      when "enter"
        idx = @model_list.selected_index rescue 0
        if models.any? && idx < models.length
          selected = models[idx]
          @remote_model_id = selected[:id]
          @remote_model_index = idx
          update_param_keys
          save_config
          # Offer best settings based on model type hint
          model_type = api_model_type(selected)
          if model_type && MODEL_BEST_SETTINGS[model_type]
            @confirm_apply_best_settings = true
            @pending_best_settings_type = model_type
            return [self, nil]
          end
        end
        return close_overlay
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
      scan_models
      [self, set_status_toast("Deleted #{File.basename(path)} (#{format_bytes(size)})")]
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
      if entry["provider"]
        match = @providers.find { |p| p.id == entry["provider"] }
        if match
          @provider = match
          @provider_index = @providers.index(match)
          @active_provider_id = match.id
          update_param_keys
        end
      end
    end

    def offer_img2img_settings(extra_cmd = nil)
      model_type = if @provider.provider_type == :local && @selected_model_path
        detect_model_type(@selected_model_path)
      end
      if model_type && IMG2IMG_BEST_SETTINGS[model_type]
        @confirm_apply_best_settings = true
        @pending_best_settings_type = model_type
        @pending_best_settings_img2img = true
      end
      [self, extra_cmd]
    end

    def build_gallery
      return unless File.directory?(@output_dir)

      # Collect regular images
      pngs = Dir.glob(File.join(@output_dir, "*.png")).sort.reverse
      entries = pngs.first(80).map do |png|
        { path: png, meta: nil, type: :image }
      end

      # Collect video frame directories — only grab first frame path lazily
      Dir.glob(File.join(@output_dir, "*_frames")).sort.reverse.first(20).each do |frames_dir|
        next unless File.directory?(frames_dir)
        first_frame = Dir.glob(File.join(frames_dir, "*.png")).min
        next unless first_frame
        entries << {
          path: first_frame,
          meta: nil,
          type: :video,
          frames_dir: frames_dir,
          frame_paths: nil, # loaded lazily on enter
          mp4_path: nil,    # loaded lazily on enter
        }
      end

      @gallery_images = entries.first(100)
      @gallery_index = 0
      @gallery_thumb_cache = {}
      @gallery_preview_ready = @kitty_graphics || @gallery_images.empty?
    end

    def gallery_meta(entry)
      return entry[:meta] if entry[:meta]
      if entry[:type] == :video && entry[:frames_dir]
        json = File.join(entry[:frames_dir], "video.json")
      else
        json = entry[:path].sub(/\.png$/, ".json")
      end
      entry[:meta] = File.exist?(json) ? (JSON.parse(File.read(json)) rescue {}) : {}
      entry[:meta]
    end

    GALLERY_DEBOUNCE = 0.15

    def gallery_debounce_preview
      @gallery_preview_ready = false
      @gallery_preview_gen += 1
      clear_kitty_images if @kitty_graphics
      gen = @gallery_preview_gen
      Bubbletea.tick(GALLERY_DEBOUNCE) { GalleryPreviewMessage.new(generation: gen) }
    end

    def gallery_load_thumb_async
      return [self, nil] if @gallery_images.empty?
      entry = @gallery_images[@gallery_index]
      return [self, nil] unless entry && entry[:path]

      if @kitty_graphics
        @gallery_preview_ready = true
        return [self, nil]
      end

      if @gallery_thumb_cache[entry[:path]]
        @gallery_preview_ready = true
        return [self, nil]
      end

      path = entry[:path]
      gen = @gallery_preview_gen
      inner_h = @height - 6
      list_w = narrow? ? @width - 4 : [(@width * 0.35).to_i, 30].max
      preview_w = @width - list_w - 8
      info_h = 8
      thumb_h = [inner_h - info_h - 2, 6].max
      max_w = preview_w - 4

      cmd = Proc.new do
        thumb = render_image_halfblocks(path, max_w, thumb_h)
        GalleryPreviewMessage.new(generation: gen, path: path, thumb: thumb)
      rescue
        GalleryPreviewMessage.new(generation: gen, path: path, thumb: nil)
      end
      [self, cmd]
    end

    def handle_gallery_key(message)
      key = message.to_s
      return close_overlay if key == "esc" || key == "q"
      return [self, nil] if @gallery_images.empty?

      nav_cmd = nil
      case key
      when "up", "k"
        @gallery_index = (@gallery_index - 1) % @gallery_images.length
        nav_cmd = gallery_debounce_preview
      when "down", "j"
        @gallery_index = (@gallery_index + 1) % @gallery_images.length
        nav_cmd = gallery_debounce_preview
      when "left", "h"
        @gallery_index = (@gallery_index - 1) % @gallery_images.length
        nav_cmd = gallery_debounce_preview
      when "right", "l"
        @gallery_index = (@gallery_index + 1) % @gallery_images.length
        nav_cmd = gallery_debounce_preview
      when "enter", " "
        entry = @gallery_images[@gallery_index]
        if entry[:type] == :video && entry[:frames_dir]
          # Lazily load frame paths on first open
          entry[:frame_paths] ||= Dir.glob(File.join(entry[:frames_dir], "*.png")).sort
          entry[:mp4_path] ||= Dir.glob(File.join(entry[:frames_dir], "*.mp4")).first
          if entry[:frame_paths].any?
            meta = gallery_meta(entry)
            @video_frame_paths = entry[:frame_paths]
            @video_frames_dir = entry[:frames_dir]
            @video_frame_index = 0
            @video_playing = false
            @video_playback_fps = (meta&.dig("fps") || @params[:fps] || 16).to_i
            @video_playback_gen += 1
            @video_mp4_path = entry[:mp4_path]
            @overlay = :video_player
            clear_kitty_images if @kitty_graphics
          else
            show_fullscreen_image(entry[:path])
          end
        else
          show_fullscreen_image(entry[:path])
        end
        return [self, nil]
      when "ctrl+e", "ctrl+o"
        open_image(@gallery_images[@gallery_index][:path])
      when "delete", "backspace"
        delete_gallery_image
      when "p"
        entry = @gallery_images[@gallery_index]
        meta = gallery_meta(entry)
        load_from_history(meta) if meta && !meta.empty?
        return close_overlay
      when "u"
        entry = @gallery_images[@gallery_index]
        return start_upscale(entry[:path]) if entry
      when "c"
        entry = @gallery_images[@gallery_index]
        return copy_image_to_clipboard(entry[:path]) if entry
      end
      [self, nav_cmd]
    end

    def delete_gallery_image
      return if @gallery_images.empty?
      entry = @gallery_images[@gallery_index]

      if entry[:type] == :video && entry[:frames_dir]
        # Validate directory is within output_dir before recursive delete
        real_dir = File.realpath(entry[:frames_dir]) rescue nil
        real_output = File.realpath(@output_dir) rescue nil
        FileUtils.rm_rf(entry[:frames_dir]) if real_dir && real_output && real_dir.start_with?(real_output + "/")
      else
        File.delete(entry[:path]) if File.exist?(entry[:path])
        json = entry[:path].sub(/\.png$/, ".json")
        File.delete(json) if File.exist?(json)
      end
      @gallery_thumb_cache.delete(entry[:path])
      @gallery_images.delete_at(@gallery_index)
      @gallery_index = [[@gallery_index, @gallery_images.length - 1].min, 0].max
      clear_kitty_images if @kitty_graphics
    end

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
        @lora_card_expanded = false
      when "down", "j"
        @lora_index = (@lora_index + 1) % [@available_loras.length, 1].max
        @lora_card_expanded = false
      when "enter", " "
        toggle_lora_selection(@lora_index)
      when "i"
        @lora_card_expanded = !@lora_card_expanded
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
      when "d"
        return enter_lora_download_mode
      end
      [self, nil]
    end

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
        cmd = all[@preset_index] ? load_preset(all[@preset_index]) : nil
        close_overlay
        return [self, cmd]
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
      toast_cmd = nil
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
      @params[:strength] = d["strength"].to_f if d["strength"]
      @params[:guidance] = d["guidance"].to_f if d["guidance"]
      @params[:video_frames] = d["video_frames"] if d["video_frames"]
      @params[:fps] = d["fps"] if d["fps"]

      # ControlNet settings
      if d.key?("cn_strength")
        @controlnet_strength = d["cn_strength"].to_f
      end
      if d.key?("cn_canny")
        @controlnet_canny = !!d["cn_canny"]
      end

      # Auto-generate mask if preset requests it
      if d["auto_mask"] == "center_preserve" && @init_image_path
        mask_path = File.join(@output_dir, ".mask_#{Time.now.strftime('%Y%m%d_%H%M%S')}.png")
        FileUtils.mkdir_p(@output_dir)
        generate_center_preserve_mask(d["width"] || @params[:width], d["height"] || @params[:height], mask_path)
        @mask_image_path = mask_path
      end

      # Model selection: exact path (user presets) or type match (builtins)
      if d["model"] && File.exist?(d["model"])
        @selected_model_path = d["model"]
        @preview_cache = nil
      elsif d["model"]
        toast_cmd = set_error_toast("Preset model is missing: #{File.basename(d["model"])}")
      elsif d["model_type"] && @provider.provider_type == :local
        selected = select_model_by_type(d["model_type"])
        unless selected
          label = d["model_type"].to_s.casecmp("wan").zero? ? "Wan video" : d["model_type"]
          toast_cmd = set_error_toast("No #{label} model is installed for this preset — press ^d to download one")
        end
      end
      update_param_keys
      toast_cmd
    end

    def save_user_preset(name)
      data = {
        "steps" => @params[:steps], "cfg_scale" => @params[:cfg_scale],
        "width" => @params[:width], "height" => @params[:height],
        "seed" => @params[:seed], "sampler" => @sampler, "scheduler" => @scheduler,
        "batch" => @params[:batch],
      }
      data["model"] = @selected_model_path if @selected_model_path
      data["strength"] = @params[:strength] if @init_image_path
      if @selected_model_path && wan_model?(@selected_model_path)
        data["video_frames"] = @params[:video_frames]
        data["fps"] = @params[:fps]
      end
      @user_presets[name] = data
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

    IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .webp .bmp].freeze

    def open_file_picker
      open_file_picker_for(:init_image)
    end

    def open_file_picker_for(target)
      @file_picker_target = target
      case @focus
      when FOCUS_PROMPT then @prompt_input.blur
      when FOCUS_NEGATIVE then @negative_input.blur
      end
      @overlay = :file_picker
      @error_message = nil
      @file_picker_dir = case target
      when :init_image
        if @init_image_path then File.dirname(@init_image_path)
        elsif File.directory?(@output_dir) then File.expand_path(@output_dir)
        else File.expand_path("~")
        end
      when :controlnet
        if @controlnet_image_path then File.dirname(@controlnet_image_path)
        elsif File.directory?(@output_dir) then File.expand_path(@output_dir)
        else File.expand_path("~")
        end
      when :mask
        if @mask_image_path then File.dirname(@mask_image_path)
        elsif File.directory?(@output_dir) then File.expand_path(@output_dir)
        else File.expand_path("~")
        end
      else
        File.expand_path("~")
      end
      scan_file_picker_dir
      kickoff_file_picker_preview
    end

    def open_controlnet_model_picker
      # If no ControlNet model installed, go straight to download
      cn_installed = RECOMMENDED_CONTROLNETS.any? { |c| File.exist?(File.join(@models_dir, c[:file])) }
      existing_cn = Dir.glob(File.join(@models_dir, "**", "*.{gguf,safetensors}")).any? { |f|
        File.basename(f).downcase.include?("control")
      }
      unless cn_installed || existing_cn || @controlnet_model_path
        return enter_controlnet_download
      end

      @file_picker_target = :cn_model
      case @focus
      when FOCUS_PROMPT then @prompt_input.blur
      when FOCUS_NEGATIVE then @negative_input.blur
      end
      @overlay = :file_picker
      @error_message = nil
      @file_picker_dir = if @controlnet_model_path
        File.dirname(@controlnet_model_path)
      else
        @models_dir || File.expand_path("~/.config/chewy/models")
      end
      scan_file_picker_dir
      kickoff_file_picker_preview
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
          else
            ext = File.extname(name).downcase
            allowed = @file_picker_target == :cn_model ? MODEL_EXTENSIONS : IMAGE_EXTENSIONS
            if allowed.include?(ext)
              # When browsing for ControlNet models, only show files with "control" in the name
              next if @file_picker_target == :cn_model && !name.downcase.include?("control")
              size = File.size(full) rescue 0
              entries << { name: name, path: full, type: :file, size: size }
            end
          end
        end
      rescue Errno::EACCES
        @error_message = "Permission denied: #{@file_picker_dir}"
      end

      @file_picker_entries = entries
      @file_picker_index = 0
      @file_picker_scroll = 0
      @file_picker_thumb_cache = {}
      @file_picker_preview_ready = @kitty_graphics || !file_picker_preview_needed?
    end

    PICKER_DEBOUNCE = 0.15 # seconds to wait before loading preview

    def file_picker_debounce_preview
      @file_picker_preview_ready = false
      @file_picker_preview_gen += 1
      clear_kitty_images if @kitty_graphics
      gen = @file_picker_preview_gen
      Bubbletea.tick(PICKER_DEBOUNCE) { FilePickerPreviewMessage.new(generation: gen) }
    end

    def file_picker_preview_needed?(entry = @file_picker_entries[@file_picker_index])
      entry && entry[:type] == :file && @file_picker_target != :cn_model
    end

    def kickoff_file_picker_preview
      @file_picker_preview_ready = @kitty_graphics || !file_picker_preview_needed?
      return [self, nil] if @file_picker_preview_ready

      file_picker_load_thumb_async
    end

    def file_picker_load_thumb_async
      entry = @file_picker_entries[@file_picker_index]
      unless file_picker_preview_needed?(entry)
        @file_picker_preview_ready = true
        return [self, nil]
      end

      if @kitty_graphics
        @file_picker_preview_ready = true
        return [self, nil]
      end

      # Already cached — show immediately
      if @file_picker_thumb_cache[entry[:path]]
        @file_picker_preview_ready = true
        return [self, nil]
      end

      # Load in background thread
      path = entry[:path]
      gen = @file_picker_preview_gen
      inner_h = @height - 6
      list_w = narrow? ? @width - 4 : [(@width * 0.45).to_i, 30].max
      preview_w = @width - list_w - 8
      max_w = preview_w - 4
      max_h = inner_h - 4

      cmd = Proc.new do
        thumb = render_image_halfblocks(path, max_w, max_h)
        FilePickerPreviewMessage.new(generation: gen, path: path, thumb: thumb)
      rescue
        FilePickerPreviewMessage.new(generation: gen, path: path, thumb: nil)
      end
      [self, cmd]
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
          return kickoff_file_picker_preview
        else
          case @file_picker_target
          when :controlnet
            @controlnet_image_path = entry[:path]
            toast = set_status_toast("ControlNet image: #{File.basename(entry[:path])}")
            close_overlay
            return [self, toast]
          when :cn_model
            @controlnet_model_path = entry[:path]
            # Auto-set control image to init image if not already set
            if !@controlnet_image_path && @init_image_path
              @controlnet_image_path = @init_image_path
            end
            toast = set_status_toast("ControlNet model: #{File.basename(entry[:path])}")
            close_overlay
            return [self, toast]
          when :mask
            @mask_image_path = entry[:path]
            toast = set_status_toast("Mask: #{File.basename(entry[:path])}")
            close_overlay
            return [self, toast]
          else
            @init_image_path = entry[:path]
            # Auto-sync control image when ControlNet is active
            @controlnet_image_path = entry[:path] if @controlnet_model_path
            toast = set_status_toast("Init image: #{File.basename(entry[:path])}")
            close_overlay
            return offer_img2img_settings(toast)
          end
        end
      when "backspace"
        # Go up one directory
        parent = File.dirname(@file_picker_dir)
        unless parent == @file_picker_dir
          @file_picker_dir = parent
          scan_file_picker_dir
          return kickoff_file_picker_preview
        end
      when "~"
        @file_picker_dir = File.expand_path("~")
        scan_file_picker_dir
        return kickoff_file_picker_preview
      end

      # Keep scroll in view
      if @file_picker_index < @file_picker_scroll
        @file_picker_scroll = @file_picker_index
      elsif @file_picker_index >= @file_picker_scroll + visible_h
        @file_picker_scroll = @file_picker_index - visible_h + 1
      end

      # Debounce preview for navigation keys
      preview_cmd = case key
      when "up", "k", "down", "j"
        file_picker_debounce_preview
      end

      [self, preview_cmd]
    end


    def handle_help_key(message)
      key = message.to_s
      case key
      when "esc", "q", "f1", "ctrl+]"
        close_overlay
      when "up", "k"
        @help_scroll = [(@help_scroll || 0) - 1, 0].max
        [self, nil]
      when "down", "j"
        @help_scroll = (@help_scroll || 0) + 1
        [self, nil]
      else
        [self, nil]
      end
    end

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
        toast = set_status_toast("Theme: #{Theme.current_name}")
        close_overlay
        return [self, toast]
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

    def handle_provider_key(message)
      key = message.to_s
      case key
      when "esc", "q"
        return close_overlay
      when "up"
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
      when "k", "s"
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
        toast = set_status_toast("Provider: #{@provider.display_name}")
        close_overlay
        return [self, toast]
      end
      [self, nil]
    end

    def handle_api_key_key(message)
      key = message.to_s
      case key
      when "esc"
        @api_key_input.value = ""
        return close_overlay
      when "ctrl+v"
        return paste_text_into(@api_key_input)
      when "enter"
        api_key = @api_key_input.value.strip
        if api_key.empty?
          return [self, set_error_toast("API key cannot be empty")]
        end
        @provider.store_api_key(api_key)
        @api_key_input.value = ""
        @overlay = nil
        @error_message = nil
        toast = set_status_toast("#{@provider.display_name} API key saved")
        case @focus
        when FOCUS_PROMPT then @prompt_input.focus
        when FOCUS_NEGATIVE then @negative_input.focus
        end
        return [self, toast]
      end
      @api_key_input, cmd = @api_key_input.update(message)
      [self, cmd]
    end

    def handle_hf_token_key(message)
      key = message.to_s
      case key
      when "esc"
        @hf_token_pending_action = nil
        @hf_token_input.value = ""
        return close_overlay
      when "ctrl+v"
        return paste_text_into(@hf_token_input)
      when "enter"
        token = @hf_token_input.value.strip
        if token.empty?
          return [self, set_error_toast("Token cannot be empty")]
        end
        save_hf_token(token)
        @hf_token_input.value = ""
        pending = @hf_token_pending_action
        @hf_token_pending_action = nil
        @overlay = nil
        toast = set_status_toast("Token saved")
        case @focus
        when FOCUS_PROMPT then @prompt_input.focus
        when FOCUS_NEGATIVE then @negative_input.focus
        end
        # Resume the action that triggered the token prompt
        return download_flux_companions if pending == :flux_companions
        return download_flux2_companions if pending == :flux2_companions
        return download_z_image_companions if pending == :z_image_companions
        return download_qwen_image_companions if pending == :qwen_image_companions
        return download_wan_companions if pending == :wan_companions
        return [self, toast]
      end
      @hf_token_input, cmd = @hf_token_input.update(message)
      [self, cmd]
    end

    def handle_tokens_key(message)
      key = message.to_s
      active = @tokens_field == 0 ? @tokens_hf_input : @tokens_civitai_input
      case key
      when "esc"
        return close_overlay
      when "tab", "down"
        @tokens_field = 1 - @tokens_field
        @tokens_hf_input.blur; @tokens_civitai_input.blur
        (@tokens_field == 0 ? @tokens_hf_input : @tokens_civitai_input).focus
        return [self, nil]
      when "shift+tab", "up"
        @tokens_field = 1 - @tokens_field
        @tokens_hf_input.blur; @tokens_civitai_input.blur
        (@tokens_field == 0 ? @tokens_hf_input : @tokens_civitai_input).focus
        return [self, nil]
      when "ctrl+v"
        return paste_text_into(active)
      when "enter"
        hf = @tokens_hf_input.value.strip
        civ = @tokens_civitai_input.value.strip
        save_hf_token(hf) unless hf.empty?
        save_civitai_token(civ) unless civ.empty?
        saved = []
        saved << "HF" unless hf.empty?
        saved << "Civitai" unless civ.empty?
        toast = saved.empty? ? set_status_toast("No tokens entered") : set_status_toast("Saved: #{saved.join(' + ')}")
        close_overlay
        return [self, toast]
      end
      if @tokens_field == 0
        @tokens_hf_input, cmd = @tokens_hf_input.update(message)
      else
        @tokens_civitai_input, cmd = @tokens_civitai_input.update(message)
      end
      [self, cmd]
    end

    # ========== Mask Painter ==========

    def handle_mask_painter_key(message)
      key = message.to_s
      case key
      when "esc", "q"
        @overlay = nil
        @mask_paint_grid = nil; @mask_paint_grid_colors = nil
        case @focus
        when FOCUS_PROMPT then @prompt_input.focus
        when FOCUS_NEGATIVE then @negative_input.focus
        end
        return [self, nil]
      when "enter"
        # Confirm — generate mask from grid and set it
        mask_path = File.join(@output_dir, ".mask_#{Time.now.strftime('%Y%m%d_%H%M%S')}.png")
        FileUtils.mkdir_p(@output_dir)
        grid_to_mask(@mask_paint_grid, @params[:width], @params[:height], mask_path)
        @mask_image_path = mask_path
        @overlay = nil
        @mask_paint_grid = nil; @mask_paint_grid_colors = nil
        case @focus
        when FOCUS_PROMPT then @prompt_input.focus
        when FOCUS_NEGATIVE then @negative_input.focus
        end
        return [self, set_status_toast("Mask saved")]
      when "i"
        # Invert the mask
        @mask_paint_grid.each do |row|
          row.map! { |v| !v }
        end
      when "c"
        # Clear (all black = keep everything)
        @mask_paint_grid.each { |row| row.fill(false) }
      when "f"
        # Fill (all white = regenerate everything)
        @mask_paint_grid.each { |row| row.fill(true) }
      when "b"
        # Toggle brush mode
        @mask_paint_brush = @mask_paint_brush == :paint ? :erase : :paint
      end
      [self, nil]
    end

    # ========== Starter Pack ==========

    def handle_starter_pack_key(message)
      key = message.to_s
      return [self, Bubbletea.quit] if key == "ctrl+c"

      if @starter_pack_downloading
        return [self, nil]
      end

      @starter_pack_selected ||= []

      case key
      when "esc", "q", "s"
        @overlay = nil
        @starter_pack_selected = []
        case @focus
        when FOCUS_PROMPT then @prompt_input.focus
        when FOCUS_NEGATIVE then @negative_input.focus
        end
        return [self, nil]
      when "up", "k"
        @starter_pack_index = (@starter_pack_index - 1) % STARTER_PACKS.length
      when "down", "j"
        @starter_pack_index = (@starter_pack_index + 1) % STARTER_PACKS.length
      when " "
        # Toggle selection
        if @starter_pack_selected.include?(@starter_pack_index)
          @starter_pack_selected.delete(@starter_pack_index)
        else
          @starter_pack_selected << @starter_pack_index
        end
      when "enter"
        if @starter_pack_selected.empty?
          # Nothing toggled — download the highlighted one
          return start_starter_pack_download_multi([@starter_pack_index])
        else
          return start_starter_pack_download_multi(@starter_pack_selected)
        end
      end
      [self, nil]
    end

    def handle_mask_painter_mouse(message)
      # Accept both press and motion (drag) events for continuous painting
      return [self, nil] unless message.press? || message.motion?
      # Map terminal coordinates to grid coordinates
      # Account for padding: 2 left, 1 top + 2 rows for title/status
      cx = message.x - 3
      cy = message.y - 4

      return [self, nil] if cx < 0 || cy < 0
      return [self, nil] unless @mask_paint_grid

      col = cx
      row = cy

      return [self, nil] if row >= @mask_paint_rows || col >= @mask_paint_cols

      # Paint with a 2-cell brush for easier coverage
      value = (@mask_paint_brush == :paint)
      (-1..1).each do |dy|
        (-1..1).each do |dx|
          r = row + dy; c = col + dx
          next if r < 0 || r >= @mask_paint_rows || c < 0 || c >= @mask_paint_cols
          @mask_paint_grid[r][c] = value
        end
      end
      [self, nil]
    end
  end
end
