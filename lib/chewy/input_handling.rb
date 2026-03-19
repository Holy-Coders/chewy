# frozen_string_literal: true

class Chewy
  module InputHandling
    private

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
        when FOCUS_PROMPT, FOCUS_NEGATIVE
          clip = read_clipboard_text
          if clip.empty?
            return paste_image_from_clipboard
          else
            input = @focus == FOCUS_PROMPT ? @prompt_input : @negative_input
            return paste_text_into(input)
          end
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

    # Read text from the system clipboard
    def read_clipboard_text
      if RUBY_PLATFORM.include?("darwin")
        `pbpaste 2>/dev/null`.strip rescue ""
      else
        text = `wl-paste --no-newline 2>/dev/null`.strip rescue ""
        return text unless text.empty?
        text = `xclip -selection clipboard -o 2>/dev/null`.strip rescue ""
        return text unless text.empty?
        `xsel --clipboard --output 2>/dev/null`.strip rescue ""
      end
    end

    # Paste text from clipboard into the given input at its cursor position
    def paste_text_into(input)
      clip = read_clipboard_text
      return [self, nil] if clip.empty?

      current = input.value
      pos = input.position
      input.value = current[0...pos].to_s + clip + current[pos..].to_s
      input.position = pos + clip.length
      [self, set_status_toast("Pasted #{clip.length} chars")]
    end

    def handle_chip_click(x, y)
      hit = @chip_hit_map.find { |h| h[:y] == y && x >= h[:x_start] && x <= h[:x_end] }
      return false unless hit

      input = hit[:target] == :prompt ? @prompt_input : @negative_input
      current = input.value
      chip = hit[:chip]

      # Check if chip is already in the text
      pattern = /(?:^|,\s*|\s+)#{Regexp.escape(chip)}(?:,\s*|\s*$)/i
      if current.match?(pattern)
        result = current.sub(/,?\s*#{Regexp.escape(chip)}/i, "").sub(/\A[,\s]+/, "").sub(/[,\s]+\z/, "")
        input.value = result
      else
        sep = current.strip.empty? ? "" : ", "
        input.value = "#{current.strip}#{sep}#{chip}"
      end
      input.cursor_end
      true
    end
  end
end
