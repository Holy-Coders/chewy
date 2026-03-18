# frozen_string_literal: true

module Chewy::InputHandling
  NARROW_THRESHOLD = 76

  private

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
    progress_w = narrow? ? [@width - 10, 20].max : [right_panel_width - 10, 20].max
    @progress = Bubbles::Progress.new(width: progress_w, gradient: [Theme.PRIMARY, Theme.ACCENT])
    @model_list.width = @width - 12 if @model_list
    @model_list.height = [@height - 10, 6].max if @model_list
    @preview_cache = nil # invalidate on resize
    clear_kitty_images if @kitty_graphics
    resize_download_lists if @overlay == :download
  end

  def resize_download_lists
    w = @width - 4; h = @height - 9  # account for search bar
    @download_search_input.width = w - 12
    @repo_list&.width = w; @repo_list&.height = h
    @file_list&.width = w; @file_list&.height = h
  end

  NARROW_THRESHOLD = 76  # inner width; corresponds to ~80 col terminal

  def narrow? = @width < NARROW_THRESHOLD
  def left_panel_width = narrow? ? @width : [(@width * 0.45).to_i, 36].max
  def right_panel_width = narrow? ? @width : @width - left_panel_width

  def narrow? = @width < NARROW_THRESHOLD
  def left_panel_width = narrow? ? @width : [(@width * 0.45).to_i, 36].max
  def right_panel_width = narrow? ? @width : @width - left_panel_width

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

  def handle_mouse(message)
    return [self, nil] unless message.press?
    return handle_overlay_mouse(message) if @overlay

    x = message.x
    y = message.y

    # Check chip clicks first — uses absolute coordinates stored during render
    return [self, nil] if handle_chip_click(x, y)

    # Account for padding: 2 chars left, 1 line top
    cx = x - 2
    cy = y - 1

    # Use shrunk dimensions to match render (view subtracts 4 from width, 2 from height)
    view_w = @width - 4
    view_h = @height - 2
    saved_w, saved_h = @width, @height
    @width, @height = view_w, view_h
    lw = left_panel_width
    prompt_h, negative_h, params_h = left_panel_heights
    @width, @height = saved_w, saved_h

    # Header row (row 0 of content)
    if cy == 0
      header_mid = lw
      if cx >= header_mid
        return toggle_overlay(:provider)
      else
        return toggle_overlay(:models)
      end
    end

    # Bottom bar (last content row)
    if cy >= view_h - 1
      return [self, nil]
    end

    # Body area
    body_y = cy - 1  # offset for header
    left_h = prompt_h + negative_h + params_h

    # Determine if click is in left panel vs right/preview panel
    in_left_panel = narrow? ? (body_y < left_h) : (cx < lw)
    in_preview = narrow? ? (body_y >= left_h) : (cx >= lw)

    if in_left_panel
      # Left panel clicks
      if body_y < prompt_h
        # Prompt section
        unless @focus == FOCUS_PROMPT
          @focus = FOCUS_PROMPT
          @prompt_input.focus
          @negative_input.blur
        end
      elsif body_y < prompt_h + negative_h
        # Negative prompt section
        unless @focus == FOCUS_NEGATIVE
          @focus = FOCUS_NEGATIVE
          @negative_input.focus
          @prompt_input.blur
        end
      else
        # Params section
        was_focused = @focus == FOCUS_PARAMS
        unless was_focused
          @focus = FOCUS_PARAMS
          @prompt_input.blur
          @negative_input.blur
        end
        # Click on specific param row when already expanded
        if was_focused
          param_row = body_y - prompt_h - negative_h - 3  # border + label + separator
          if param_row >= 0 && param_row < @param_display_keys.length
            if @param_index == param_row
              # Click same param again — start editing or cycle
              key = @param_display_keys[param_row]
              if key == :sampler
                @sampler_index = (@sampler_index + 1) % SAMPLER_OPTIONS.length
                @sampler = SAMPLER_OPTIONS[@sampler_index]
              elsif key == :scheduler
                @scheduler_index = (@scheduler_index + 1) % SCHEDULER_OPTIONS.length
                @scheduler = SCHEDULER_OPTIONS[@scheduler_index]
              else
                @editing_param = true
                @param_edit_buffer = param_value(key).to_s
              end
            else
              @param_index = param_row
              @editing_param = false
            end
          end
        end
      end
    elsif in_preview
      # Preview area clicks — open fullscreen
      if @last_output_path && !@generating
        show_fullscreen_image(@last_output_path)
      end
    end

    [self, nil]
  end

  def handle_overlay_mouse(message)
    return [self, nil] unless message.press?

    case @overlay
    when :models
      # Click on model list item
      cy = message.y - 4  # account for padding + title + separator
      if cy >= 0 && @model_list
        @model_list, _ = @model_list.update(message)
      end
    when :provider
      # Click on provider item
      cy = message.y - 4
      idx = cy / 3  # each provider takes ~3 lines (name + model + gap)
      if idx >= 0 && idx < @providers.length
        @provider_index = idx
      end
    when :theme
      cy = message.y - 4
      idx = cy / 3  # each theme takes ~3 lines (name + swatch + gap)
      if idx >= 0 && idx < THEME_NAMES.length
        @theme_index = idx
        Theme.set(THEME_NAMES[@theme_index])
      end
    when :fullscreen_image
      return close_overlay
    when :gallery
      # Click anywhere in gallery
      nil
    end

    [self, nil]
  end

  # ========== Key Handling ==========

  def handle_key(message)
    return handle_overlay_key(message) if @overlay
    handle_main_key(message)
  end

  def handle_main_key(message)
    key = message.to_s

    # Handle img2img best-settings confirmation on main view
    if @confirm_apply_best_settings && @pending_best_settings_img2img
      source = IMG2IMG_BEST_SETTINGS[@pending_best_settings_type]
      if key == "y" && source
        load_preset({ data: source })
      end
      @confirm_apply_best_settings = false
      @pending_best_settings_type = nil
      @pending_best_settings_img2img = false
      return [self, nil]
    end

    # Global shortcuts (work everywhere, including text inputs)
    # Note: ctrl+m=Enter, ctrl+h=Backspace, ctrl+i=Tab are indistinguishable in terminals
    case key
    when "ctrl+c" then return [self, Bubbletea.quit]
    when "ctrl+q" then return [self, Bubbletea.quit]
    when "ctrl+n" then return toggle_overlay(:models)     # n = navigate models
    when "ctrl+d" then return enter_download_mode
    when "ctrl+g" then return toggle_overlay(:gallery)     # g = gallery
    when "ctrl+l" then return toggle_overlay(:lora)
    when "ctrl+p" then return toggle_overlay(:preset)
    when "ctrl+t" then return toggle_overlay(:theme)
    when "ctrl+a" then return toggle_overlay(:gallery)    # a = album/gallery
    when "ctrl+o", "ctrl+e" then open_image(@last_output_path) if @last_output_path; return [self, nil]
    when "ctrl+f" then show_fullscreen_image(@last_output_path) if @last_output_path; return [self, nil]
    when "ctrl+r" then @params[:seed] = -1; return [self, nil]
    when "ctrl+b" then return open_file_picker                  # b = browse init image
    when "ctrl+v"                                                # v = paste
      case @focus
      when FOCUS_PROMPT   then return paste_text_into(@prompt_input)
      when FOCUS_NEGATIVE then return paste_text_into(@negative_input)
      else return paste_image_from_clipboard
      end
    when "ctrl+u"
      unless @focus == FOCUS_PROMPT || @focus == FOCUS_NEGATIVE
        @init_image_path = nil; return [self, set_status_toast("Init image cleared")]
      end
    when "ctrl+x" then if @generating; @gen_cancelled = true; @provider.cancel(@gen_pid) if @provider.capabilities.cancel && @gen_pid; end; return [self, nil]
    when "ctrl+y" then return toggle_overlay(:provider)
    when "f1", "ctrl+]" then return toggle_overlay(:help)
    when "tab"    then cycle_focus; return [self, nil]
    when "shift+tab" then cycle_focus(reverse: true); return [self, nil]
    when "ctrl+w"
      # Clear prompt, image, and reset to starting state
      @prompt_input.value = ""; @negative_input.value = ""
      @last_output_path = nil; @last_generation_time = nil; @last_seed = nil
      @init_image_path = nil; @preview_cache = nil; @preview_path = nil
      clear_kitty_images if @kitty_graphics
      @focus = FOCUS_PROMPT; @prompt_input.focus; @negative_input.blur
      return [self, set_status_toast("Cleared")]
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
      elsif current_key == :cn_model
        return open_controlnet_model_picker
      elsif current_key == :cn_image
        return open_file_picker_for(:controlnet)
      elsif current_key == :cn_canny
        @controlnet_canny = !@controlnet_canny
      elsif current_key == :cn_strength
        @editing_param = true
        @param_edit_buffer = @controlnet_strength.to_s
      else
        @editing_param = true
        @param_edit_buffer = param_value(current_key).to_s
      end
    when "left", "right"
      if current_key == :sampler
        dir = key == "left" ? -1 : 1
        @sampler_index = (@sampler_index + dir) % SAMPLER_OPTIONS.length
        @sampler = SAMPLER_OPTIONS[@sampler_index]
      elsif current_key == :scheduler
        dir = key == "left" ? -1 : 1
        @scheduler_index = (@scheduler_index + dir) % SCHEDULER_OPTIONS.length
        @scheduler = SCHEDULER_OPTIONS[@scheduler_index]
      elsif current_key == :cn_canny
        @controlnet_canny = !@controlnet_canny
      end
    end
    [self, nil]
  end

  def param_value(key)
    case key
    when :sampler then @sampler
    when :scheduler then @scheduler
    when :cn_model then @controlnet_model_path ? File.basename(@controlnet_model_path) : "none"
    when :cn_image then @controlnet_image_path ? File.basename(@controlnet_image_path) : "none"
    when :cn_strength then @controlnet_strength
    when :cn_canny then @controlnet_canny ? "on" : "off"
    else @params[key]
    end
  end

  def commit_param_edit
    key = @param_display_keys[@param_index]
    return if key == :sampler || key == :scheduler

    if key == :cn_strength
      @controlnet_strength = @param_edit_buffer.to_f.clamp(0.0, 1.0)
      @editing_param = false; @param_edit_buffer = ""
      return
    end

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

  def load_prompt_history_from_disk
    dir = ENV["CHEWY_OUTPUT_DIR"] || @config["output_dir"] || "outputs"
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

  # ========== Overlay Key Handling ==========

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

  # -- Model picker keys --

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
          return [self, set_error_toast("#{m[:name]} is already installed")]
        end
        return [self, start_model_download(m[:repo], m[:file], m[:size])]
      elsif idx == PRELOADED_MODELS.length
        return enter_hf_search_mode
      else
        return enter_civitai_search_mode
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
    return paste_text_into(@download_search_input) if key == "ctrl+v"
    if key == "enter"
      query = @download_search_input.value.strip
      if @download_source == :civitai
        # CivitAI: empty query returns popular results
        @fetching = true
        @download_search_input.blur
        @download_search_focused = false
        return [self, fetch_civitai_models_cmd(query)]
      else
        return [self, nil] if query.empty?
        # Auto-append gguf for FLUX searches — sd.cpp can't load raw FLUX safetensors
        query += " gguf" if query.downcase.include?("flux") && !query.downcase.include?("gguf")
        @fetching = true
        @download_search_input.blur
        @download_search_focused = false
        return [self, fetch_repos_cmd(query)]
      end
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
      idx = @repo_list.selected_index rescue 0
      if @download_source == :civitai
        return [self, nil] if idx >= @civitai_models.length
        m = @civitai_models[idx]
        return show_civitai_files(m)
      else
        item = @repo_list.selected_item
        return [self, fetch_files_cmd(item[:title])] if item && item[:title] != "No models found"
        return [self, nil]
      end
    end
    @repo_list, cmd = @repo_list.update(message)
    [self, cmd]
  end

  def handle_file_list_key(message)
    return [self, nil] unless @file_list
    if message.to_s == "enter"
      idx = @file_list.selected_index rescue 0
      if @download_source == :civitai
        return [self, nil] if idx >= (@civitai_selected_files || []).length
        f = @civitai_selected_files[idx]
        return [self, start_civitai_download(f[:name], f[:url], f[:size])]
      else
        item = @file_list.selected_item
        if item && item[:title] != "No compatible files"
          fd = @remote_files.find { |ff| ff["path"] == item[:title] }
          return [self, start_model_download(@selected_repo_id, item[:title], fd&.dig("size") || 0)]
        end
        return [self, nil]
      end
    end
    @file_list, cmd = @file_list.update(message)
    [self, cmd]
  end

  def show_civitai_files(model)
    @download_view = :files
    @selected_repo_id = model[:name]
    @civitai_selected_files = model[:files]
    items = model[:files].map do |f|
      { title: f[:name], description: f[:size] ? format_bytes(f[:size]) : "unknown" }
    end
    items = [{ title: "No compatible files", description: "" }] if items.empty?
    @file_list = Bubbles::List.new(items, width: @width - 4, height: @height - 9)
    @file_list.title = ""
    @file_list.show_status_bar = false
    @file_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    @file_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    [self, nil]
  end

  def start_civitai_download(filename, url, size)
    FileUtils.mkdir_p(@models_dir)
    dest = File.join(@models_dir, filename); part = "#{dest}.part"
    @model_downloading = true; @download_dest = part
    @download_total = size || 0; @download_filename = filename; @error_message = nil
    Proc.new do
      _out, err, st = Open3.capture3("curl", "-fL", "-o", part, "-s",
        "-C", "-", "--retry", "5", "--retry-delay", "3", "--retry-all-errors",
        "--connect-timeout", "30", url)
      if st.success?
        File.rename(part, dest)
        ModelDownloadDoneMessage.new(path: dest, filename: filename)
      else
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
    when "p"
      entry = @gallery_images[@gallery_index]
      load_from_history(entry[:meta]) if entry[:meta] && !entry[:meta].empty?
      return close_overlay
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
    clear_kitty_images if @kitty_graphics
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

  def toggle_lora_selection(idx)
    return if idx >= @available_loras.length
    lora = @available_loras[idx]
    existing = @selected_loras.find_index { |l| l[:path] == lora[:path] }
    if existing
      @selected_loras.delete_at(existing)
    else
      meta = lora_metadata(lora)
      default_weight = meta.dig(:recommended_weight, :default) || 1.0
      @selected_loras << { name: lora[:name], path: lora[:path], weight: default_weight }
    end
  end

  def adjust_lora_weight(idx, delta)
    return if idx >= @available_loras.length
    lora = @available_loras[idx]
    sel = @selected_loras.find { |l| l[:path] == lora[:path] }
    sel[:weight] = (sel[:weight] + delta).round(1).clamp(0.0, 2.0) if sel
  end

  def handle_lora_download_key(message)
    key = message.to_s
    case key
    when "esc"
      return [self, nil] if @lora_downloading
      if @lora_search_focused
        @lora_search_input.blur
        @lora_search_focused = false
        return [self, nil]
      end
      return lora_back_to_repos if @lora_download_view == :files
      return lora_back_to_recommended if @lora_download_view == :repos
      return exit_lora_download_mode
    when "q"
      return [self, nil] if @lora_downloading || @lora_search_focused
      return lora_back_to_repos if @lora_download_view == :files
      return lora_back_to_recommended if @lora_download_view == :repos
      return exit_lora_download_mode
    when "tab"
      if @lora_download_view == :repos
        @lora_search_focused = !@lora_search_focused
        @lora_search_focused ? @lora_search_input.focus : @lora_search_input.blur
        return [self, nil]
      end
    end
    return [self, nil] if @fetching || @lora_downloading

    if @lora_search_focused
      return handle_lora_search_key(message)
    end

    case @lora_download_view
    when :recommended then handle_lora_recommended_key(message)
    when :repos then handle_lora_repo_list_key(message)
    when :files then handle_lora_file_list_key(message)
    else [self, nil]
    end
  end

  def handle_lora_recommended_key(message)
    return [self, nil] unless @lora_recommended_list
    if message.to_s == "enter"
      idx = @lora_recommended_list.selected_index rescue 0
      filtered = @lora_recommended_filtered || []
      # Account for "No recommended LoRAs" placeholder item
      has_placeholder = filtered.empty? && current_model_family
      rec_count = filtered.length + (has_placeholder ? 1 : 0)
      if idx < filtered.length
        l = filtered[idx]
        dest = File.join(@lora_dir, l[:file])
        if File.exist?(dest)
          return [self, set_error_toast("#{l[:name]} is already installed")]
        end
        return [self, start_lora_download(l[:repo], l[:file], l[:size])]
      elsif idx == rec_count
        return enter_lora_hf_search_mode
      else
        return enter_lora_civitai_search_mode
      end
    end
    @lora_recommended_list, cmd = @lora_recommended_list.update(message)
    [self, cmd]
  end

  def enter_lora_civitai_search_mode
    @lora_download_view = :repos
    @lora_download_source = :civitai
    @error_message = nil; @fetching = false
    @lora_search_input.value = ""
    @lora_search_input.placeholder = "Search CivitAI LoRAs..."
    @lora_search_input.focus
    @lora_search_focused = true
    @lora_repo_list = nil
    [self, nil]
  end

  def handle_lora_search_key(message)
    key = message.to_s
    return paste_text_into(@lora_search_input) if key == "ctrl+v"
    if key == "enter"
      query = @lora_search_input.value.strip
      if @lora_download_source == :civitai
        @fetching = true
        @lora_search_input.blur
        @lora_search_focused = false
        return [self, fetch_civitai_models_cmd(query, type: "LORA")]
      else
        return [self, nil] if query.empty?
        @fetching = true
        @lora_search_input.blur
        @lora_search_focused = false
        return [self, fetch_lora_repos_cmd(query)]
      end
    end
    @lora_search_input, cmd = @lora_search_input.update(message)
    [self, cmd]
  end

  def handle_lora_repo_list_key(message)
    return [self, nil] unless @lora_repo_list
    if message.to_s == "enter"
      idx = @lora_repo_list.selected_index rescue 0
      if @lora_download_source == :civitai
        return [self, nil] if idx >= @lora_civitai_models.length
        m = @lora_civitai_models[idx]
        return show_lora_civitai_files(m)
      else
        item = @lora_repo_list.selected_item
        return [self, fetch_lora_files_cmd(item[:title])] if item && item[:title] != "No LoRAs found"
        return [self, nil]
      end
    end
    @lora_repo_list, cmd = @lora_repo_list.update(message)
    [self, cmd]
  end

  def handle_lora_file_list_key(message)
    return [self, nil] unless @lora_file_list
    if message.to_s == "enter"
      idx = @lora_file_list.selected_index rescue 0
      if @lora_download_source == :civitai
        return [self, nil] if idx >= (@lora_civitai_selected_files || []).length
        f = @lora_civitai_selected_files[idx]
        return [self, start_lora_civitai_download(f[:name], f[:url], f[:size])]
      end
      item = @lora_file_list.selected_item
      if item && item[:title] != "No .safetensors files found"
        fd = @lora_remote_files.find { |f| f["path"] == item[:title] }
        return [self, start_lora_download(@lora_selected_repo_id, item[:title], fd&.dig("size") || 0)]
      end
      return [self, nil]
    end
    @lora_file_list, cmd = @lora_file_list.update(message)
    [self, cmd]
  end

  def lora_back_to_recommended
    @lora_download_view = :recommended; @lora_file_list = nil; @lora_repo_list = nil
    @lora_remote_files = []; @lora_remote_repos = []; @lora_selected_repo_id = nil; @error_message = nil
    @lora_search_input.blur; @lora_search_focused = false
    build_lora_recommended_list
    [self, nil]
  end

  def lora_back_to_repos
    @lora_download_view = :repos; @lora_file_list = nil; @lora_remote_files = []
    @lora_selected_repo_id = nil; @error_message = nil
    @lora_search_focused = false; @lora_search_input.blur
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

    [self, nil]
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
      return [self, toast]
    end
    @hf_token_input, cmd = @hf_token_input.update(message)
    [self, cmd]
  end
end
