# frozen_string_literal: true

module Chewy
  module Views
    module Main
      private

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
        if @confirm_apply_best_settings && @pending_best_settings_img2img
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

        # Provider badge for remote providers
        provider_badge = if @provider.provider_type == :api
          prov_label = Lipgloss::Style.new.background(Theme.SECONDARY).foreground(Theme.BAR_TEXT).bold(true)
            .render(" #{@provider.display_name} ")
          model_name = @remote_model_id || @provider.list_models.first&.dig(:id) || "default"
          " #{dim.render("\u2502")} #{prov_label} #{Lipgloss::Style.new.foreground(Theme.TEXT).bold(true).render(model_name)}"
        else
          ""
        end

        model_info = if @provider.provider_type == :local
          if @selected_model_path
            name = File.basename(@selected_model_path, File.extname(@selected_model_path))
            is_flux = flux_model?(@selected_model_path)
            cached_type = @model_types[@selected_model_path]

            quant = name.match(/[_-](Q\d_\w+|F16|F32|q\d_\w+|f16|f32)/i)&.captures&.first&.upcase

            type_label = if is_flux || cached_type == "FLUX"
              ok = flux_companions_present?
              pill_bg = ok ? Theme.SUCCESS : Theme.WARNING
              " #{Lipgloss::Style.new.background(pill_bg).foreground(Theme.SURFACE).bold(true).render(" FLUX ")}"
            elsif quant
              " #{Lipgloss::Style.new.background(Theme.SECONDARY).foreground(Theme.BAR_TEXT).bold(true).render(" #{quant} ")}"
            elsif cached_type
              " #{Lipgloss::Style.new.background(Theme.SECONDARY).foreground(Theme.BAR_TEXT).render(" #{cached_type} ")}"
            else
              " #{Lipgloss::Style.new.background(Theme.BORDER_DIM).foreground(Theme.TEXT).render(" SD ")}"
            end
            " #{dim.render("\u2502")} #{Lipgloss::Style.new.foreground(Theme.TEXT).bold(true).render(name)}#{type_label}"
          else
            " #{dim.render("\u2502")} #{dim.render("no model selected")}"
          end
        else
          provider_badge
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

        left = "#{logo}#{model_info}#{img2img_badge}#{controlnet_badge}"

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

      COLLAPSED_H = 1  # height for unfocused sections in narrow mode

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

      def render_left_panel
        lw = left_panel_width
        prompt_h, negative_h, params_h = left_panel_heights

        prompt_section = render_prompt_section(lw, prompt_h)
        negative_section = render_negative_section(lw, negative_h)
        params_section = render_params_section(lw, params_h)

        Lipgloss.join_vertical(:left, prompt_section, negative_section, params_section)
      end

      IMAGE_PAD_Y = 2  # vertical padding above/below image in right panel

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
        dim = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
        key_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
        desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
        center = ->(s) { Lipgloss::Style.new.width(max_w).align(:center).render(s) }

        # Show logo in empty preview area
        logo_path = File.join(__dir__, "logo.png")
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
        ]
        hint_lines = hints.map { |k, d| "#{key_style.render(k.ljust(7))} #{desc_style.render(d)}" }
        max_hint_w = hints.map { |k, d| 7 + 1 + d.length }.max
        pad = [(max_w - max_hint_w) / 2, 0].max
        hint_lines.each { |l| lines << (" " * pad) + l }

        pad_top = [(max_h - lines.length) / 2, 0].max
        (Array.new(pad_top, "") + lines).join("\n")
      end

      def render_bottom_bar
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
          [["enter", "generate"], ["tab", "focus"], ["^n", "models"]]
        when FOCUS_NEGATIVE
          [["enter", "generate"], ["tab", "focus"], ["^n", "models"]]
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
end
