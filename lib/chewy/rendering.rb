# frozen_string_literal: true

class Chewy
  module Rendering
    private

    NARROW_THRESHOLD = 76  # inner width; corresponds to ~80 col terminal

    COLLAPSED_H = 1  # height for unfocused sections in narrow mode

    IMAGE_PAD_Y = 2  # vertical padding above/below image in right panel

    REVEAL_PHASES = 10 # phases 0..9: very blocky → full resolution
    REVEAL_DELAYS = [0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.10, 0.12, 0.14, 0.0].freeze

    SPLASH_PHASES = 6 # phases 0..5: very blocky → clear → dismiss
    SPLASH_PIXELATE = [32, 16, 8, 4, 2, nil].freeze
    SPLASH_DELAYS = [0.3, 0.25, 0.2, 0.15, 0.8, 0.0].freeze # linger at full res before dismiss

    PROMPT_CHIPS = [
      "photorealistic", "cinematic lighting", "8k uhd", "detailed",
      "oil painting", "watercolor", "anime style", "pixel art",
      "studio portrait", "landscape", "macro photography", "fantasy art",
      "minimalist", "surreal", "concept art", "isometric",
    ].freeze

    NEGATIVE_CHIPS = [
      "blurry", "low quality", "deformed", "ugly",
      "bad anatomy", "watermark", "text", "signature",
      "cropped", "out of frame", "duplicate", "noise",
    ].freeze

    CHIP_GAP = 2  # spaces between chips

    # Refresh all input widget styles from the active theme (needed for live theme switching).
    # Skips work when the theme hasn't changed since last call.
    def apply_theme_styles
      current_theme = Theme.current_name
      return if @_last_applied_theme == current_theme

      @_last_applied_theme = current_theme

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
      @_empty_preview_cache = nil  # invalidate logo cache on theme change
    end

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
      if @first_run
        @first_run_toast = false
        @overlay = :starter_pack
        return [self, nil]
      end
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

    def render_splash
      logo_path = File.join(CHEWY_ROOT, "logo.png")
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

    def resize_components
      lw = left_panel_width
      @prompt_input.width = lw - 6
      @negative_input.width = lw - 6
      progress_w = narrow? ? [@width - 10, 20].max : [right_panel_width - 10, 20].max
      @progress = Bubbles::Progress.new(width: progress_w, gradient: [Theme.PRIMARY, Theme.ACCENT])
      @model_list.width = @width - 12 if @model_list
      @model_list.height = [@height - 10, 6].max if @model_list
      @preview_cache = nil # invalidate on resize
      @_empty_preview_cache = nil
      clear_kitty_images if @kitty_graphics
      resize_download_lists if @overlay == :download
    end

    def resize_download_lists
      w = @width - 4; h = @height - 9  # account for search bar
      @download_search_input.width = w - 12
      @repo_list&.width = w; @repo_list&.height = h
      @file_list&.width = w; @file_list&.height = h
    end

    def narrow? = @width < NARROW_THRESHOLD
    def left_panel_width = narrow? ? @width : [(@width * 0.45).to_i, 36].max
    def right_panel_width = narrow? ? @width : @width - left_panel_width

    def left_panel_heights
      body_h = @height - 2  # header + bottom bar

      if narrow?
        # In narrow (stacked) mode, unfocused sections collapse to 1 row
        max_h = [(body_h * 0.4).to_i, 8].max
        params_h = @focus == FOCUS_PARAMS ? [@param_display_keys.length + 4, (max_h * 0.6).to_i].max : 3

        case @focus
        when FOCUS_PROMPT
          negative_h = COLLAPSED_H
          prompt_h = [max_h - negative_h - params_h, 4].max
        when FOCUS_NEGATIVE
          prompt_h = COLLAPSED_H
          negative_h = [max_h - prompt_h - params_h, 4].max
        when FOCUS_PARAMS
          prompt_h = COLLAPSED_H
          negative_h = COLLAPSED_H
          params_h = [max_h - prompt_h - negative_h, params_h].min
        else
          prompt_h = COLLAPSED_H
          negative_h = COLLAPSED_H
        end

        # Clamp total
        total = prompt_h + negative_h + params_h
        if total > max_h
          overflow = total - max_h
          case @focus
          when FOCUS_PROMPT
            prompt_h = [prompt_h - overflow, 3].max
          when FOCUS_NEGATIVE
            negative_h = [negative_h - overflow, 3].max
          else
            params_h = [params_h - overflow, 3].max
          end
        end

        return [prompt_h, negative_h, params_h]
      end

      # Wide layout — original logic
      if @focus == FOCUS_PARAMS
        params_min = @param_display_keys.length + 4
        params_h = [params_min, (body_h * 0.30).to_i].max
      else
        params_h = 3
      end

      remaining = [body_h - params_h, 8].max
      prompt_h = [(remaining * 0.6).to_i, 5].max
      negative_h = [remaining - prompt_h, 4].max

      total = prompt_h + negative_h + params_h
      if total > body_h
        overflow = total - body_h
        shrink = [overflow, prompt_h - 3].min
        prompt_h -= shrink; overflow -= shrink
        shrink = [overflow, negative_h - 2].min
        negative_h -= shrink; overflow -= shrink
        params_h -= overflow if overflow > 0
      end

      [prompt_h, negative_h, params_h]
    end

    def render_main_view
      header = render_header
      bottom = render_bottom_bar

      if narrow?
        left = render_left_panel
        preview = render_narrow_preview
        body = Lipgloss.join_vertical(:left, left, preview)
      else
        left = render_left_panel
        right = render_right_panel
        body = Lipgloss.join_horizontal(:top, left, right)
      end

      result = Lipgloss.join_vertical(:left, header, body, bottom)
      if @confirm_low_memory
        result += render_low_memory_popup
      elsif @confirm_apply_best_settings && @pending_best_settings_img2img
        result += render_best_settings_popup
      end

      # Clear stale kitty preview when generating or during reveal animation
      if @kitty_graphics && (@generating || @reveal_phase)
        result << "\e_Ga=d,d=I,i=20,q=2\e\\"
      end

      # Register kitty overlay for main preview — must match render_image_preview dimensions
      if @kitty_graphics && !@generating && @last_output_path && File.exist?(@last_output_path) && @reveal_phase.nil?
        prompt_h, negative_h, params_h = left_panel_heights
        total_left = prompt_h + negative_h + params_h
        body_h = @height - 2

        if narrow?
          preview_h = [body_h - total_left, 3].max
          img_w = @width - 2
          img_h = [preview_h - 2, 1].max
          img_col = 2 + 1 + 1  # outer_pad_left + padding (1-based)
          img_row = 1 + 1 + total_left + 1  # outer_pad_top + header + left_panel + padding
        else
          rw = right_panel_width
          total_left = [total_left, body_h].min
          img_w = rw - 2
          img_h = [total_left - IMAGE_PAD_Y * 2, 1].max
          # Terminal position (1-based): outer padding (2 cols, 1 row) + left panel + right panel padding (1 col)
          img_col = 2 + left_panel_width + 1 + 1  # outer_pad_left + left_panel + right_panel_pad_left (1-based)
          img_row = 1 + 1 + IMAGE_PAD_Y  # outer_pad_top + header + image_pad_top
        end

        @kitty_overlay_pending = { path: @last_output_path, row: img_row, col: img_col, w: img_w, h: img_h, slot: 20 }
      end

      result
    end

    def render_header
      logo = Theme.gradient_text(" chewy ", Theme.PRIMARY, Theme.ACCENT)
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)

      # Provider pill — always shown
      prov_pill = Lipgloss::Style.new.background(Theme.SECONDARY).foreground(Theme.BAR_TEXT).bold(true)
        .render(" #{@provider.display_name} ")
      provider_section = " #{dim.render("\u2502")} #{prov_pill}"

      model_info = if @provider.provider_type == :local
        if @selected_model_path
          name = File.basename(@selected_model_path, File.extname(@selected_model_path))
          is_flux = flux_model?(@selected_model_path)
          is_flux2 = flux2_model?(@selected_model_path)
          cached_type = @model_types[@selected_model_path]

          quant = name.match(/[_-](Q\d_\w+|F16|F32|q\d_\w+|f16|f32)/i)&.captures&.first&.upcase

          is_wan = wan_model?(@selected_model_path)
          type_label = if is_wan || cached_type == "Wan"
            ok = wan_companions_present?
            pill_bg = ok ? Theme.SUCCESS : Theme.WARNING
            Lipgloss::Style.new.background(pill_bg).foreground(Theme.SURFACE).bold(true).render(" VIDEO ")
          elsif is_flux2 || cached_type == "FLUX2"
            ok = flux2_companions_present?
            pill_bg = ok ? Theme.SUCCESS : Theme.WARNING
            Lipgloss::Style.new.background(pill_bg).foreground(Theme.SURFACE).bold(true).render(" FLUX.2 ")
          elsif z_image_model?(@selected_model_path) || cached_type == "Z-Image"
            ok = z_image_companions_present?
            pill_bg = ok ? Theme.SUCCESS : Theme.WARNING
            Lipgloss::Style.new.background(pill_bg).foreground(Theme.SURFACE).bold(true).render(" Z-IMAGE ")
          elsif qwen_image_model?(@selected_model_path) || cached_type == "Qwen-Image"
            ok = qwen_image_companions_present?
            pill_bg = ok ? Theme.SUCCESS : Theme.WARNING
            Lipgloss::Style.new.background(pill_bg).foreground(Theme.SURFACE).bold(true).render(" QWEN ")
          elsif kontext_model?(@selected_model_path)
            ok = flux_companions_present?
            pill_bg = ok ? Theme.SUCCESS : Theme.WARNING
            Lipgloss::Style.new.background(pill_bg).foreground(Theme.SURFACE).bold(true).render(" KONTEXT ")
          elsif chroma_model?(@selected_model_path) || cached_type == "Chroma"
            ok = flux_companions_present?
            pill_bg = ok ? Theme.SUCCESS : Theme.WARNING
            Lipgloss::Style.new.background(pill_bg).foreground(Theme.SURFACE).bold(true).render(" CHROMA ")
          elsif is_flux || cached_type == "FLUX"
            ok = flux_companions_present?
            pill_bg = ok ? Theme.SUCCESS : Theme.WARNING
            Lipgloss::Style.new.background(pill_bg).foreground(Theme.SURFACE).bold(true).render(" FLUX ")
          elsif cached_type
            Lipgloss::Style.new.background(Theme.SECONDARY).foreground(Theme.BAR_TEXT).render(" #{cached_type} ")
          elsif quant
            Lipgloss::Style.new.background(Theme.SECONDARY).foreground(Theme.BAR_TEXT).bold(true).render(" #{quant} ")
          else
            Lipgloss::Style.new.background(Theme.BORDER_DIM).foreground(Theme.TEXT).render(" SD ")
          end
          " #{dim.render("\u2502")} #{type_label} #{Lipgloss::Style.new.foreground(Theme.TEXT).bold(true).render(name)}"
        else
          " #{dim.render("\u2502")} #{dim.render("no model selected")}"
        end
      else
        model_name = @remote_model_id || @provider.list_models.first&.dig(:id) || "default"
        " #{dim.render("\u2502")} #{Lipgloss::Style.new.foreground(Theme.TEXT).bold(true).render(model_name)}"
      end

      img2img_badge = if @init_image_path && @provider.capabilities.img2img
        name = File.basename(@init_image_path)
        name = name[0, 20] + "..." if name.length > 23
        i2i = Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true)
        " #{dim.render("\u2502")} #{i2i.render("img2img")} #{dim.render(name)}"
      else
        ""
      end

      controlnet_badge = if @controlnet_model_path && @provider.capabilities.controlnet
        cn = Lipgloss::Style.new.foreground(Theme.SUCCESS).bold(true)
        name = File.basename(@controlnet_model_path)
        name = name[0, 15] + "..." if name.length > 18
        " #{dim.render("\u2502")} #{cn.render("CN")} #{dim.render(name)}"
      else
        ""
      end

      mask_badge = if @mask_image_path
        mk = Lipgloss::Style.new.foreground(Theme.WARNING).bold(true)
        name = File.basename(@mask_image_path)
        name = name[0, 15] + "..." if name.length > 18
        " #{dim.render("\u2502")} #{mk.render("MASK")} #{dim.render(name)}"
      else
        ""
      end

      left = "#{logo}#{provider_section}#{model_info}#{img2img_badge}#{controlnet_badge}#{mask_badge}"

      if narrow?
        # Truncate left content to fit and skip right-side hints
        Lipgloss::Style.new.width(@width).max_width(@width).background(Theme.SURFACE).render(left)
      else
        right = dim.render("[^y] provider  [^n] models  [^l] loras ")

        # Right-align the hint
        left_visible = left.gsub(/\e\[[0-9;]*[A-Za-z]/, "").length
        right_visible = right.gsub(/\e\[[0-9;]*[A-Za-z]/, "").length
        gap = [@width - left_visible - right_visible, 1].max

        Lipgloss::Style.new.width(@width).background(Theme.SURFACE).render("#{left}#{' ' * gap}#{right}")
      end
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
      body_h = @height - 2  # header + bottom bar
      total_left = [total_left, body_h].min
      img_h = [total_left - IMAGE_PAD_Y * 2, 1].max

      content = if @generating
        render_generating_preview(rw - 2, img_h)
      elsif @last_output_path && File.exist?(@last_output_path)
        render_image_preview(rw - 2, img_h)
      else
        render_empty_preview(rw - 2, img_h)
      end

      Lipgloss::Style.new
        .background(Theme.SURFACE)
        .width(rw - 2).height(total_left).padding(IMAGE_PAD_Y, 1).render(content)
    end

    # Stacked preview panel for narrow/mobile layout
    def render_narrow_preview
      prompt_h, negative_h, params_h = left_panel_heights
      left_h = prompt_h + negative_h + params_h
      body_h = @height - 2
      preview_h = [body_h - left_h, 3].max
      pw = @width
      img_h = [preview_h - 2, 1].max  # 1 row padding top/bottom

      content = if @generating
        render_generating_preview(pw - 2, img_h)
      elsif @last_output_path && File.exist?(@last_output_path)
        render_image_preview(pw - 2, img_h)
      else
        render_empty_preview(pw - 2, img_h)
      end

      Lipgloss::Style.new
        .background(Theme.SURFACE)
        .width(pw).height(preview_h).padding(1, 1).render(content)
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

      img_str = render_image(@last_output_path, max_w, max_h, pixelate: pixelate, corner_radius: 3, kitty_overlay: @kitty_graphics)
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
        status_lines << center.call(dim.render(elapsed_str)) if elapsed > 0
      end

      if @gen_total_batch > 1
        batch_text = "Batch #{@gen_current_batch}/#{@gen_total_batch}"
        status_lines << center.call(Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render(batch_text))
      end

      if @generation_queue && @generation_queue.length > 0
        qtext = "#{@generation_queue.length} queued"
        status_lines << center.call(Lipgloss::Style.new.foreground(Theme.ACCENT).render(qtext))
      end

      if @gen_video_frame && @gen_video_frame_total && @gen_video_frame_total > 0
        video_text = "Frame #{@gen_video_frame}/#{@gen_video_frame_total}"
        status_lines << center.call(Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true).render(video_text))
      end

      # Try to show live preview image
      gap = 2
      preview_img = load_gen_preview(max_w, max_h - status_lines.length - gap)

      if preview_img
        centered_img = center_image(preview_img, max_w)
        (centered_img + "\n" * gap + status_lines.join("\n"))
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
      cache_key = [max_w, max_h]
      return @_empty_preview_cache if @_empty_preview_cache && @_empty_preview_key == cache_key

      dim = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
      key_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      center = ->(s) { Lipgloss::Style.new.width(max_w).align(:center).render(s) }

      # Show logo in empty preview area
      logo_path = File.join(CHEWY_ROOT, "logo.png")
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
        ["^t", "themes (custom supported)"],
      ]
      hint_lines = hints.map { |k, d| "#{key_style.render(k.ljust(7))} #{desc_style.render(d)}" }
      max_hint_w = hints.map { |k, d| 7 + 1 + d.length }.max
      pad = [(max_w - max_hint_w) / 2, 0].max
      hint_lines.each { |l| lines << (" " * pad) + l }

      pad_top = [(max_h - lines.length) / 2, 0].max
      result = (Array.new(pad_top, "") + lines).join("\n")
      @_empty_preview_cache = result
      @_empty_preview_key = cache_key
      result
    end

    def render_wrapped_input(input, max_lines:)
      value = input.value
      width = [input.width, 1].max
      max_lines = [max_lines, 1].max

      if value.empty? || value.chars.length <= width
        # Single-line fast path — record a no-wrap layout so click-to-cursor works
        @input_layouts ||= {}
        @input_layouts[input.object_id] = { width: width, start_line: 0, wrapped: false }
        return input.view
      end

      lines, positions = wrapped_input_layout(value, width)
      cursor_line, cursor_col = positions[input.position]
      start_line = [cursor_line - max_lines + 1, 0].max
      visible_lines = lines[start_line, max_lines] || []

      @input_layouts ||= {}
      @input_layouts[input.object_id] = { width: width, start_line: start_line, wrapped: true }

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

      # Narrow collapsed: single summary line
      if narrow? && !focused && box_h <= COLLAPSED_H
        dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
        val = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
        preview = @prompt_input.value.strip
        preview = preview.empty? ? "empty" : preview[0, tw - 12]
        return Lipgloss::Style.new.width(tw).background(Theme.SURFACE)
          .render(" #{dim.render("Prompt:")} #{val.render(preview)}")
      end

      label_style = Lipgloss::Style.new.foreground(focused ? Theme.PRIMARY : Theme.TEXT_DIM).bold(focused)
      inner_w = tw - 4  # width inside the border + padding

      # AI enhance button — right-aligned on the label row
      ai_button = if @prompt_enhancing
        "#{@spinner.view} #{Lipgloss::Style.new.foreground(Theme.TEXT_DIM).italic(true).render("enhancing...")}"
      elsif focused
        btn_text = @prompt_input.value.strip.empty? ? " \u2728 Generate " : " \u2728 Enhance "
        Lipgloss::Style.new.background(Theme.PRIMARY).foreground(Theme.BAR_TEXT).bold(true).render(btn_text)
      else
        nil
      end

      if ai_button
        label_text = "Prompt"
        btn_visible_w = ai_button.gsub(/\e\[[0-9;]*[A-Za-z]/, "").length
        gap = [inner_w - label_text.length - btn_visible_w, 1].max
        label_row = "#{label_style.render(label_text)}#{' ' * gap}#{ai_button}"
      else
        label_row = label_style.render("Prompt")
      end

      lora_tags = if @selected_loras.any?
        pill = Lipgloss::Style.new.background(Theme.ACCENT).foreground(Theme.SURFACE).bold(true)
        dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
        tags = @selected_loras.map { |l| pill.render(" #{l[:name]}:#{l[:weight]} ") }
        "\n#{dim.render("LoRA")} #{tags.join(' ')}"
      else
        ""
      end

      # Skip chips in narrow mode to save space
      chips_line = if focused && !narrow?
        render_chips(PROMPT_CHIPS, tw - 6, @prompt_input.value, target: :prompt)
      else
        ""
      end
      extra_lines = lora_tags.count("\n") + (chips_line.empty? ? 0 : chips_line.count("\n") + 2)

      # Register AI button click target — right-aligned on the label row
      if focused && !@prompt_enhancing
        btn_text = @prompt_input.value.strip.empty? ? " \u2728 Generate " : " \u2728 Enhance "
        btn_visible_w = btn_text.length
        # Button X position: outer_padding(2) + border(1) + inner gap pushes it right
        btn_x_end = 2 + tw - 2  # right edge of the box content area
        btn_x_start = btn_x_end - btn_visible_w
        # Button Y position: outer_padding(1) + header(1) + border(1) = row 3 is the label row
        btn_y = 1 + 1 + 1  # outer_pad_top + header_row + border_top
        @chip_hit_map << {
          y: btn_y,
          x_start: btn_x_start,
          x_end: btn_x_end,
          chip: :ai_enhance,
          target: :ai_enhance,
        }
      end

      prompt_lines = [box_h - 4 - extra_lines, 1].max
      prompt_view = render_wrapped_input(@prompt_input, max_lines: prompt_lines)
      content = "#{label_row}\n#{prompt_view}#{lora_tags}"
      unless chips_line.empty?
        content += "\n\n#{chips_line}"
        actual_lines = prompt_view.count("\n") + 1
        chips_base_y = 1 + 1 + 1 + 1 + actual_lines + lora_tags.count("\n") + 1
        register_chip_hits(PROMPT_CHIPS, tw - 6, @prompt_input.value, chips_base_y, :prompt)
      end

      border_color = focused ? gradient_border_color : Theme.BORDER_DIM
      Lipgloss::Style.new.border(:rounded).border_foreground(border_color).background(Theme.SURFACE)
        .width(tw - 2).height(box_h - 2).render(content)
    end

    def render_negative_section(tw, box_h)
      focused = @focus == FOCUS_NEGATIVE

      # Narrow collapsed: single summary line
      if narrow? && !focused && box_h <= COLLAPSED_H
        dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
        val = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
        preview = @negative_input.value.strip
        preview = preview.empty? ? "empty" : preview[0, tw - 14]
        return Lipgloss::Style.new.width(tw).background(Theme.SURFACE)
          .render(" #{dim.render("Negative:")} #{val.render(preview)}")
      end

      label_style = Lipgloss::Style.new.foreground(focused ? Theme.ACCENT : Theme.TEXT_DIM).bold(focused)
      label = label_style.render("Negative Prompt")

      # Skip chips in narrow mode to save space
      chips_line = if focused && !narrow?
        render_chips(NEGATIVE_CHIPS, tw - 6, @negative_input.value, target: :negative)
      else
        ""
      end
      extra_lines = chips_line.empty? ? 0 : chips_line.count("\n") + 2

      negative_lines = [box_h - 3 - extra_lines, 1].max
      negative_view = render_wrapped_input(@negative_input, max_lines: negative_lines)
      content = "#{label}\n#{negative_view}"
      unless chips_line.empty?
        content += "\n\n#{chips_line}"
        p_h, _, _ = left_panel_heights
        actual_lines = negative_view.count("\n") + 1
        chips_base_y = 1 + 1 + p_h + 1 + 1 + actual_lines + 1
        register_chip_hits(NEGATIVE_CHIPS, tw - 6, @negative_input.value, chips_base_y, :negative)
      end

      border_color = focused ? gradient_border_color : Theme.BORDER_DIM
      Lipgloss::Style.new.border(:rounded).border_foreground(border_color).background(Theme.SURFACE)
        .width(tw - 2).height(box_h - 2).render(content)
    end

    def register_chip_hits(chips, max_w, current_text, base_y, target)
      # Build hit map by replaying the same layout logic as render_chips
      current_x = 0; row = 0
      # +3 for border(1) + left padding in box(1) + 1 extra
      x_offset = 3
      chips.each do |chip|
        chip_w = chip.length + 2  # " chip " visible width
        needed = current_x == 0 ? chip_w : current_x + CHIP_GAP + chip_w
        if needed > max_w && current_x > 0
          row += 1; current_x = 0
        end
        @chip_hit_map << {
          y: base_y + row,
          x_start: x_offset + current_x,
          x_end: x_offset + current_x + chip_w - 1,
          chip: chip,
          target: target,
        }
        current_x += chip_w + CHIP_GAP
      end
    end

    def render_chips(chips, max_w, current_text, target: nil)
      active = Lipgloss::Style.new.background(Theme.PRIMARY).foreground(Theme.SURFACE).bold(true)
      inactive = Lipgloss::Style.new.background(Theme.BORDER_DIM).foreground(Theme.TEXT_DIM)

      rendered = chips.map do |chip|
        pattern = /(?:^|,\s*|\s+)#{Regexp.escape(chip)}(?:,|\s|$)/i
        used = current_text.match?(pattern)
        style = used ? active : inactive
        style.render(" #{chip} ")
      end

      gap = " " * CHIP_GAP

      # Wrap chips to fit within max_w
      lines = [+""]
      rendered.each do |chip|
        visible = chip.gsub(/\e\[[0-9;]*[A-Za-z]/, "").length
        line_visible = lines.last.gsub(/\e\[[0-9;]*[A-Za-z]/, "").length
        needed = lines.last.empty? ? visible : line_visible + CHIP_GAP + visible
        if needed > max_w && !lines.last.empty?
          lines << +""
        end
        lines.last << gap unless lines.last.empty?
        lines.last << chip
      end

      lines.join("\n")
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
        elsif key == :cn_model
          hint = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).render(" (enter: browse | d: download)")
          "#{val_style.render(value.to_s)}#{hint}"
        elsif key == :cn_image
          hint = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).render(" (enter to browse)")
          "#{val_style.render(value.to_s)}#{hint}"
        elsif key == :mask_image
          hint = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).render(" (enter: browse | g: auto | p: paint | x: clear)")
          "#{val_style.render(value.to_s)}#{hint}"
        elsif key == :cn_canny
          toggle = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
          "#{toggle.render("<")} #{val_style.render(value.to_s)} #{toggle.render(">")}"
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
      when :guidance then "Guidance "
      when :scheduler then "Schedule "
      when :threads then "Threads  "
      when :cn_model then "CN Model "
      when :cn_image then "CN Image "
      when :cn_strength then "CN Str   "
      when :cn_canny then "CN Canny "
      when :mask_image then "Mask     "
      when :video_frames then "Frames   "
      when :fps then "FPS      "
      else key.to_s.ljust(9)
      end
    end

    def render_bottom_bar
      if @confirm_low_memory
        bar = Lipgloss::Style.new.background(Theme.ERROR).foreground(Theme.BAR_TEXT).width(@width).padding(0, 1)
        return bar.render("y: generate anyway | any key: cancel")
      end

      if @confirm_apply_best_settings && @pending_best_settings_img2img
        bar = Lipgloss::Style.new.background(Theme.SURFACE).foreground(Theme.TEXT).width(@width).padding(0, 1)
        return bar.render("y: apply img2img settings | any key: skip")
      end

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
        bar = Lipgloss::Style.new.background(Theme.PRIMARY).foreground(Theme.BAR_TEXT).width(@width).padding(0, 1)
        return bar.render(@status_message)
      end

      # No toast — show shortcuts on surface background
      Lipgloss::Style.new.width(@width).padding(0, 1).background(Theme.SURFACE).render(right)
    end

    def context_keys
      keys = case @focus
      when FOCUS_PROMPT
        [["enter", "generate"], ["tab", "focus"], ["^n", "models"], ["\u2325e", "enhance"]]
      when FOCUS_NEGATIVE
        [["enter", "generate"], ["tab", "focus"], ["^n", "models"], ["\u2325n", "auto-neg"]]
      when FOCUS_PARAMS
        [["enter", "edit"], ["j/k", "nav"], ["tab", "focus"]]
      else
        [["tab", "focus"], ["^n", "models"]]
      end

      keys << ["^x", "cancel"] if @generating
      keys << ["^e", "open"] if @last_output_path && !@generating
      keys << ["^w", "clear"] if @last_output_path && !@generating
      keys << ["^a", "gallery"] unless @generating
      keys << ["^p", "preset"] unless @generating
      keys << ["F1", "help"]

      # Trim to fit narrow screens
      if narrow?
        max_keys = @width > 50 ? 4 : 3
        keys = keys[0, max_keys]
      end

      keys
    end
  end
end
