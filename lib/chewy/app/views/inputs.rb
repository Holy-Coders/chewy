# frozen_string_literal: true

module Chewy
  module Views
    module Inputs
      private

      def render_wrapped_input(input, max_lines:)
        value = input.value
        width = [input.width, 1].max
        max_lines = [max_lines, 1].max

        return input.view if value.empty? || value.chars.length <= width

        lines, positions = wrapped_input_layout(value, width)
        cursor_line, cursor_col = positions[input.position]
        start_line = [cursor_line - max_lines + 1, 0].max
        visible_lines = lines[start_line, max_lines] || []

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
        label = label_style.render("Prompt")

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

        prompt_lines = [box_h - 4 - extra_lines, 1].max
        prompt_view = render_wrapped_input(@prompt_input, max_lines: prompt_lines)
        content = "#{label}\n#{prompt_view}#{lora_tags}"
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

      CHIP_GAP = 2  # spaces between chips

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
        separator = dim.render("\u2500" * [tw - 6, 4].max)

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
          elsif key == :cn_model || key == :cn_image
            hint = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).render(" (enter to browse)")
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
        when :scheduler then "Schedule "
        when :threads then "Threads  "
        when :cn_model then "CN Model "
        when :cn_image then "CN Image "
        when :cn_strength then "CN Str   "
        when :cn_canny then "CN Canny "
        else key.to_s.ljust(9)
        end
      end
    end
  end
end
