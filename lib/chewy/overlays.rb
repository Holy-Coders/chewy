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

      case name
      when :models then @provider.provider_type == :api ? scan_api_models : scan_models
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

    def handle_overlay_key(message)
      key = message.to_s
      return [self, Bubbletea.quit] if key == "ctrl+c"

      case @overlay
      when :models   then handle_models_panel_key(message)
      when :download then handle_download_key(message)
      when :lora     then handle_lora_panel_key(message)
      when :lora_download then handle_lora_download_key(message)
      when :help     then handle_help_key(message)
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

    def handle_models_panel_key(message)
      key = message.to_s

      # Handle best-settings confirmation popup
      if @confirm_apply_best_settings
        case key
        when "y"
          source = @pending_best_settings_img2img ? IMG2IMG_BEST_SETTINGS : MODEL_BEST_SETTINGS
          settings = source[@pending_best_settings_type]
          load_preset({ data: settings }) if settings
          @confirm_apply_best_settings = false
          @pending_best_settings_type = nil
          @pending_best_settings_img2img = false
          return close_overlay
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

      pngs = Dir.glob(File.join(@output_dir, "*.png")).sort.reverse
      @gallery_images = pngs.first(200).map do |png|
        json = png.sub(/\.png$/, ".json")
        meta = File.exist?(json) ? (JSON.parse(File.read(json)) rescue {}) : {}
        { path: png, meta: meta }
      end
      @gallery_index = 0
      @gallery_thumb_cache = {}
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
        show_fullscreen_image(@gallery_images[@gallery_index][:path])
        return [self, nil]
      when "ctrl+e", "ctrl+o"
        open_image(@gallery_images[@gallery_index][:path])
      when "delete", "backspace"
        delete_gallery_image
      when "p"
        entry = @gallery_images[@gallery_index]
        load_from_history(entry[:meta]) if entry[:meta] && !entry[:meta].empty?
        return close_overlay
      end
      [self, nav_cmd]
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
      @params[:strength] = d["strength"].to_f if d["strength"]

      # Model selection: exact path (user presets) or type match (builtins)
      if d["model"] && File.exist?(d["model"])
        @selected_model_path = d["model"]
        @preview_cache = nil
      elsif d["model_type"] && @provider.provider_type == :local
        select_model_by_type(d["model_type"])
      end
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
      else
        File.expand_path("~")
      end
      scan_file_picker_dir
      [self, nil]
    end

    def open_controlnet_model_picker
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
      [self, nil]
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
    end

    PICKER_DEBOUNCE = 0.15 # seconds to wait before loading preview

    def file_picker_debounce_preview
      @file_picker_preview_ready = false
      @file_picker_preview_gen += 1
      clear_kitty_images if @kitty_graphics
      gen = @file_picker_preview_gen
      Bubbletea.tick(PICKER_DEBOUNCE) { FilePickerPreviewMessage.new(generation: gen) }
    end

    def file_picker_load_thumb_async
      entry = @file_picker_entries[@file_picker_index]
      return [self, nil] unless entry && entry[:type] == :file && @file_picker_target != :cn_model

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
        else
          case @file_picker_target
          when :controlnet
            @controlnet_image_path = entry[:path]
            toast = set_status_toast("ControlNet image: #{File.basename(entry[:path])}")
            close_overlay
            return [self, toast]
          when :cn_model
            @controlnet_model_path = entry[:path]
            toast = set_status_toast("ControlNet model: #{File.basename(entry[:path])}")
            close_overlay
            return [self, toast]
          else
            @init_image_path = entry[:path]
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

      # Debounce preview for navigation keys
      preview_cmd = case key
      when "up", "k", "down", "j"
        file_picker_debounce_preview
      end

      [self, preview_cmd]
    end

    HELP_SECTIONS = [
      ["Generation", [
        ["enter", "Generate image"],
        ["^x", "Cancel generation"],
        ["^w", "Clear prompt & image (new start)"],
        ["^r", "Randomize seed"],
      ]],
      ["Navigation", [
        ["tab", "Cycle focus (prompt / negative / params)"],
        ["shift+tab", "Cycle focus backwards"],
        ["up/down", "Prompt history (in prompt field)"],
        ["j/k", "Navigate params (in params)"],
        ["h/l", "Adjust param value (in params)"],
      ]],
      ["Overlays", [
        ["^n", "Model picker"],
        ["^d", "Download models"],
        ["^l", "LoRA selector"],
        ["^p", "Presets"],
        ["^t", "Theme picker"],
        ["^y", "Switch provider"],
        ["^a", "Gallery"],
      ]],
      ["Image", [
        ["^b", "Browse for init image (img2img)"],
        ["^v", "Paste (text in prompt, image elsewhere)"],
        ["^u", "Clear init image"],
        ["^e", "Open last image in viewer"],
        ["^f", "Fullscreen image preview"],
      ]],
      ["App", [
        ["F1", "Toggle this help"],
        ["^q", "Quit"],
      ]],
    ].freeze

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
        return [self, toast]
      end
      @hf_token_input, cmd = @hf_token_input.update(message)
      [self, cmd]
    end
  end
end
