# frozen_string_literal: true

class Chewy
  module OverlayRendering
    private

    def render_models_content
      if @provider.provider_type == :api
        return render_api_models_content
      end

      return Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("No models found — press d to download") if @model_paths.empty?
      return Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("Loading...") unless @model_list

      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      accent = Lipgloss::Style.new.foreground(Theme.ACCENT)

      list_view = @model_list.view

      # Show metadata for highlighted model
      idx = @model_list.selected_index rescue 0
      meta = ""
      if @model_paths.any? && idx < @model_paths.length
        path = @model_paths[idx]
        if File.exist?(path)
          stat = File.stat(path)
          ext = File.extname(path).delete(".").upcase
          is_flux = flux_model?(path)

          type_tag = if is_flux
            ok = flux_companions_present?
            s = Lipgloss::Style.new.foreground(ok ? Theme.SUCCESS : Theme.WARNING).bold(true)
            s.render(ok ? "FLUX" : "FLUX (needs companions)")
          else
            dim.render("SD")
          end

          pin = @pinned_models.include?(path) ? accent.render(" [pinned]") : ""
          meta = "\n#{accent.render(format_bytes(stat.size))} #{dim.render("|")} #{dim.render(ext)} #{dim.render("|")} #{type_tag}#{pin}"
          meta += "\n#{dim.render(path)}"
        end
      end

      result = "#{list_view}#{meta}"
      result += render_best_settings_popup if @confirm_apply_best_settings
      result
    end

    def render_api_models_content
      models = @api_model_entries || @provider.list_models
      return Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("No models available") if models.empty?
      return Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("Loading...") unless @model_list

      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      accent = Lipgloss::Style.new.foreground(Theme.ACCENT)

      list_view = @model_list.view

      # Show description for highlighted model
      idx = @model_list.selected_index rescue 0
      meta = ""
      if models.any? && idx < models.length
        m = models[idx]
        active = m[:id] == @remote_model_id
        active_badge = active ? accent.render(" [active]") : ""
        meta = "\n#{dim.render(m[:desc] || "")}#{active_badge}"
        meta += "\n#{dim.render(m[:id])}"
      end

      result = "#{list_view}#{meta}"
      result += render_best_settings_popup if @confirm_apply_best_settings
      result
    end

    def render_low_memory_popup
      warn_style = Lipgloss::Style.new.foreground(Theme.ERROR).bold(true)
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      lines = []
      lines << ""
      lines << warn_style.render("Low memory warning")
      lines << dim.render(@low_memory_warning) if @low_memory_warning
      lines << ""
      lines << dim.render("Generation may be slow or crash.")
      lines.join("\n")
    end

    def render_best_settings_popup
      type = @pending_best_settings_type
      source = @pending_best_settings_img2img ? IMG2IMG_BEST_SETTINGS : MODEL_BEST_SETTINGS
      settings = source[type]
      return "" unless settings

      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      highlight = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      accent = Lipgloss::Style.new.foreground(Theme.ACCENT)

      label = @pending_best_settings_img2img ? "img2img" : type
      lines = []
      lines << ""
      lines << highlight.render("Apply recommended #{label} settings?")
      lines << ""
      parts = []
      parts << "#{accent.render("steps")}: #{dim.render(settings["steps"].to_s)}" if settings["steps"]
      parts << "#{accent.render("cfg")}: #{dim.render(settings["cfg_scale"].to_s)}" if settings["cfg_scale"]
      parts << "#{accent.render("strength")}: #{dim.render(settings["strength"].to_s)}" if settings["strength"]
      if settings["width"] && settings["height"]
        parts << "#{accent.render("size")}: #{dim.render("#{settings["width"]}×#{settings["height"]}")}"
      end
      lines << "  #{parts.join("  ")}"
      if settings["sampler"]
        lines << "  #{accent.render("sampler")}: #{dim.render(settings["sampler"])}  #{accent.render("scheduler")}: #{dim.render(settings["scheduler"] || "")}"
      end
      lines.join("\n")
    end

    def render_models_status
      if @confirm_apply_best_settings
        return "y: apply settings | any key: skip"
      end
      if @provider.provider_type == :api
        "enter: select | esc: close"
      else
        "enter: select | f: pin | d: download | del: delete | esc: close"
      end
    end

    def render_overlay_panel(title, content, status_text)
      # Title bar
      title_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      title_bar = "#{title_style.render(title)}"
      separator = dim.render("─" * (@width - 6))

      body_content = "#{title_bar}\n#{separator}\n#{content}"
      body = Lipgloss::Style.new
        .border(:rounded).border_foreground(Theme.PRIMARY).background(Theme.SURFACE)
        .width(@width - 4).height(@height - 4).padding(0, 1).render(body_content)

      # Status uses help bar style
      key_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).bold(true)
      desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
      status = Lipgloss::Style.new.width(@width).padding(0, 1).background(Theme.SURFACE)
        .render(format_help_text(status_text, key_style, desc_style))

      Lipgloss.join_vertical(:left, body, status)
    end

    def format_help_text(text, key_style, desc_style)
      # Parse "key: action | key: action" format into styled text
      parts = text.split(" | ")
      sep = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).render(" | ")
      parts.map do |part|
        if part.include?(": ")
          k, d = part.split(": ", 2)
          "#{key_style.render(k)} #{desc_style.render(d)}"
        else
          desc_style.render(part)
        end
      end.join(sep)
    end

    def render_download_view
      source_label = @download_source == :civitai ? "CivitAI" : "HuggingFace"
      content = if @fetching
        "#{@spinner.view} #{Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("Searching #{source_label}...")}"
      elsif @download_view == :recommended && @recommended_list
        @recommended_list.view
      elsif @download_view == :repos && @repo_list
        @repo_list.view
      elsif @download_view == :files && @file_list
        @file_list.view
      else
        Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("Loading...")
      end

      title = case @download_view
      when :recommended then "Recommended Models"
      when :files then "Files in #{@selected_repo_id}"
      else "#{source_label} Models"
      end
      title_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      separator = dim.render("─" * (@width - 6))

      # Search bar (only on repos view)
      search_bar = if @download_view == :repos
        border_color = @download_search_focused ? Theme.BORDER_FOCUS : Theme.BORDER_DIM
        search_label = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("Search: ")
        Lipgloss::Style.new.border(:rounded).border_foreground(border_color).background(Theme.SURFACE)
          .width(@width - 8).render("#{search_label}#{@download_search_input.view}")
      end

      parts = [title_style.render(title), separator]
      parts << search_bar if search_bar
      parts << content
      body_content = parts.join("\n")

      body = Lipgloss::Style.new
        .border(:rounded).border_foreground(Theme.PRIMARY).background(Theme.SURFACE)
        .width(@width - 4).height(@height - 4).padding(0, 1).render(body_content)
      status = render_download_status_bar
      Lipgloss.join_vertical(:left, body, status)
    end

    def render_download_status_bar
      if @model_downloading
        current = (File.size(@download_dest) rescue 0)
        pct = @download_total > 0 ? (current.to_f / @download_total) : 0
        bar = @progress.view_as(pct.clamp(0.0, 1.0))
        size_text = @download_total > 0 ?
          "#{format_bytes(current)} / #{format_bytes(@download_total)}" :
          format_bytes(current)

        download_bar = Lipgloss::Style.new.background(Theme.SECONDARY).foreground(Theme.BAR_TEXT).width(@width).padding(0, 1)
        return download_bar.render("#{@spinner.view} #{@download_filename} #{bar} #{size_text}")
      end

      if @error_message
        error_bar = Lipgloss::Style.new.background(Theme.ERROR).foreground(Theme.BAR_TEXT).width(@width).padding(0, 1)
        return error_bar.render("! #{@error_message}")
      end

      status_text = if @status_message
        @status_message
      elsif @download_view == :recommended
        "enter: download | esc: close"
      elsif @download_view == :files
        "enter: download | esc: back"
      elsif @download_search_focused
        "enter: search | esc: unfocus | tab: toggle"
      else
        "tab: search | enter: browse | esc: back"
      end

      key_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).bold(true)
      desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
      Lipgloss::Style.new.width(@width).padding(0, 1).background(Theme.SURFACE)
        .render(format_help_text(status_text, key_style, desc_style))
    end

    def render_lora_download_view
      source_label = @lora_download_source == :civitai ? "CivitAI" : "HuggingFace"
      content = if @fetching
        "#{@spinner.view} #{Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("Searching #{source_label}...")}"
      elsif @lora_download_view == :recommended && @lora_recommended_list
        @lora_recommended_list.view
      elsif @lora_download_view == :repos && @lora_repo_list
        @lora_repo_list.view
      elsif @lora_download_view == :files && @lora_file_list
        @lora_file_list.view
      else
        Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("Loading...")
      end

      family = current_model_family
      family_suffix = family ? " [#{family}]" : ""
      title = case @lora_download_view
      when :recommended then "Recommended LoRAs#{family_suffix}"
      when :files then "Files in #{@lora_selected_repo_id}"
      else "#{source_label} LoRAs"
      end
      title_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      separator = dim.render("\u2500" * (@width - 6))

      search_bar = if @lora_download_view == :repos
        border_color = @lora_search_focused ? Theme.BORDER_FOCUS : Theme.BORDER_DIM
        search_label = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("Search: ")
        Lipgloss::Style.new.border(:rounded).border_foreground(border_color).background(Theme.SURFACE)
          .width(@width - 8).render("#{search_label}#{@lora_search_input.view}")
      end

      parts = [title_style.render(title), separator]
      parts << search_bar if search_bar
      parts << content
      body_content = parts.join("\n")

      body = Lipgloss::Style.new
        .border(:rounded).border_foreground(Theme.PRIMARY).background(Theme.SURFACE)
        .width(@width - 4).height(@height - 4).padding(0, 1).render(body_content)
      status = render_lora_download_status_bar
      Lipgloss.join_vertical(:left, body, status)
    end

    def render_lora_download_status_bar
      if @lora_downloading
        current = (File.size(@lora_download_dest) rescue 0)
        pct = @lora_download_total > 0 ? (current.to_f / @lora_download_total) : 0
        bar = @progress.view_as(pct.clamp(0.0, 1.0))
        size_text = @lora_download_total > 0 ?
          "#{format_bytes(current)} / #{format_bytes(@lora_download_total)}" :
          format_bytes(current)
        download_bar = Lipgloss::Style.new.background(Theme.SECONDARY).foreground(Theme.BAR_TEXT).width(@width).padding(0, 1)
        return download_bar.render("#{@spinner.view} #{@lora_download_filename} #{bar} #{size_text}")
      end

      if @error_message
        error_bar = Lipgloss::Style.new.background(Theme.ERROR).foreground(Theme.BAR_TEXT).width(@width).padding(0, 1)
        return error_bar.render("! #{@error_message}")
      end

      status_text = if @lora_download_view == :recommended
        "enter: download | esc: back"
      elsif @lora_download_view == :files
        "enter: download | esc: back"
      elsif @lora_search_focused
        "enter: search | esc: unfocus | tab: toggle"
      else
        "tab: search | enter: browse | esc: back"
      end

      key_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).bold(true)
      desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
      Lipgloss::Style.new.width(@width).padding(0, 1).background(Theme.SURFACE)
        .render(format_help_text(status_text, key_style, desc_style))
    end

    def render_fullscreen_image
      return render_empty_preview(@width, @height) unless @fullscreen_image_path

      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      hint = dim.render("press any key to go back")

      img_h = @height - 2
      img_w = @width

      if @kitty_graphics
        # Kitty mode: raw escape sequence, no lipgloss wrapping
        img = render_image_kitty(@fullscreen_image_path, img_w, img_h, slot: 10, rounded: false)
        if img
          "#{img}\n#{hint}"
        else
          # Fallback to halfblocks
          img = render_image_halfblocks(@fullscreen_image_path, img_w, img_h)
          "#{img || "(failed to load)"}\n#{hint}"
        end
      else
        # Halfblock mode
        img = render_image_halfblocks(@fullscreen_image_path, img_w, img_h)
        "#{img || "(failed to load)"}\n#{hint}"
      end
    end

    def render_gallery_view
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      title_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      sel_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      meta_key = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      meta_val = Lipgloss::Style.new.foreground(Theme.TEXT)

      if @gallery_images.empty?
        content = dim.render("No images found in #{@output_dir}")
        return render_overlay_panel("Gallery", content, "esc: close")
      end

      inner_h = @height - 6
      list_w = narrow? ? @width - 4 : [(@width * 0.35).to_i, 30].max
      preview_w = narrow? ? 0 : @width - list_w - 8

      # -- Left: image list --
      entry = @gallery_images[@gallery_index]
      meta = gallery_meta(entry)

      visible = inner_h - 2
      half = visible / 2
      scroll_offset = if @gallery_index < half
                        0
                      elsif @gallery_index >= @gallery_images.length - half
                        [@gallery_images.length - visible, 0].max
                      else
                        @gallery_index - half
                      end

      list_lines = @gallery_images.each_with_index.map do |img, i|
        next nil if i < scroll_offset || i >= scroll_offset + visible

        fname = File.basename(img[:path], ".png")
        prompt = (gallery_meta(img)["prompt"] || "")[0, list_w - 6]
        label = prompt.empty? ? fname : prompt
        if i == @gallery_index
          sel_style.render("> #{label}")
        else
          "  #{dim.render(label)}"
        end
      end.compact

      # In narrow mode, add metadata below the list
      if narrow?
        list_lines << ""
        list_lines << "#{meta_key.render("File:")} #{meta_val.render(File.basename(entry[:path]))}"
        if meta["steps"] || meta["seed"]
          parts = []
          parts << "steps:#{meta["steps"]}" if meta["steps"]
          parts << "cfg:#{meta["cfg_scale"]}" if meta["cfg_scale"]
          parts << "#{meta["width"]}x#{meta["height"]}" if meta["width"]
          parts << "seed:#{meta["seed"]}" if meta["seed"]
          list_lines << meta_key.render(parts.join(" | "))
        end
      end

      counter = dim.render("#{@gallery_index + 1}/#{@gallery_images.length}")
      list_content = list_lines.join("\n") + "\n" + counter
      list_panel = Lipgloss::Style.new
        .border(:rounded).border_foreground(Theme.PRIMARY).background(Theme.SURFACE)
        .width(list_w).height(inner_h).padding(0, 1)
        .render(list_content)

      if narrow?
        body = list_panel
      else
        # -- Right: preview + metadata --
        info_lines = []
        info_lines << "#{meta_key.render("File:")} #{meta_val.render(File.basename(entry[:path]))}"
        info_lines << "#{meta_key.render("Prompt:")} #{meta_val.render((meta["prompt"] || "-")[0, preview_w - 12])}" if meta["prompt"]
        if meta["negative_prompt"] && !meta["negative_prompt"].empty?
          info_lines << "#{meta_key.render("Negative:")} #{meta_val.render(meta["negative_prompt"][0, preview_w - 14])}"
        end
        info_lines << "#{meta_key.render("Provider:")} #{meta_val.render(meta["provider_name"] || meta["provider"] || "-")}" if meta["provider"]
        info_lines << "#{meta_key.render("Model:")} #{meta_val.render(File.basename(meta["model"] || "-"))}" if meta["model"]
        if meta["steps"] || meta["seed"]
          parts = []
          parts << "steps:#{meta["steps"]}" if meta["steps"]
          parts << "cfg:#{meta["cfg_scale"]}" if meta["cfg_scale"]
          parts << "#{meta["width"]}x#{meta["height"]}" if meta["width"]
          parts << "seed:#{meta["seed"]}" if meta["seed"]
          info_lines << meta_key.render(parts.join(" | "))
        end
        if meta["generation_time_seconds"]
          info_lines << "#{meta_key.render("Time:")} #{meta_val.render("#{meta["generation_time_seconds"]}s")}"
        end

        info_h = info_lines.length + 1
        thumb_h = [inner_h - info_h - 2, 6].max

        preview_content = if !@gallery_preview_ready
          center_loading = Lipgloss::Style.new.width(preview_w - 4).align(:center)
            .render(dim.render("Loading..."))
          pad_top = [(thumb_h / 2), 0].max
          (Array.new(pad_top, "") << center_loading).join("\n") + "\n\n" + info_lines.join("\n")
        else
          thumb = if @kitty_graphics
            render_image(entry[:path], preview_w - 4, thumb_h, kitty_overlay: true)
          else
            @gallery_thumb_cache[entry[:path]]
          end
          thumb_str = thumb || dim.render("Loading...")
          thumb_str + "\n\n" + info_lines.join("\n")
        end

        preview_panel = Lipgloss::Style.new
          .border(:rounded).border_foreground(Theme.BORDER_DIM).background(Theme.SURFACE)
          .width(preview_w).height(inner_h).padding(0, 1)
          .render(preview_content)

        body = Lipgloss.join_horizontal(:top, list_panel, preview_panel)

        # Register kitty overlay for gallery thumbnail (only when preview is ready)
        if @gallery_preview_ready && @kitty_graphics && entry[:path] && File.exist?(entry[:path])
          gallery_img_row = 1 + 1 + 1 + 1
          gallery_img_col = 2 + 1 + list_w + 1 + 1
          @kitty_overlay_pending = { path: entry[:path], row: gallery_img_row, col: gallery_img_col, w: preview_w - 4, h: thumb_h, slot: 21 }
        end
      end

      title_bar = title_style.render("Gallery") + "  " + dim.render("#{@gallery_images.length} images")
      outer = Lipgloss::Style.new.padding(0, 1).render(
        Lipgloss.join_vertical(:left, title_bar, body)
      )

      status_text = "enter: fullscreen | p: load params | ^e: open external | del: delete | j/k: navigate | esc: close"
      key_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).bold(true)
      desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
      status = Lipgloss::Style.new.width(@width).padding(0, 1).background(Theme.SURFACE)
        .render(format_help_text(status_text, key_style, desc_style))

      Lipgloss.join_vertical(:left, outer, status)
    end

    def gallery_thumb(path, max_w, max_h)
      # Skip cache when kitty overlay handles rendering
      return render_image(path, max_w, max_h, kitty_overlay: true) if @kitty_graphics

      cached = @gallery_thumb_cache[path]
      return cached if cached

      # Limit cache to 20 entries to avoid excessive memory use
      @gallery_thumb_cache.shift if @gallery_thumb_cache.size >= 20

      thumb = render_image(path, max_w, max_h)
      @gallery_thumb_cache[path] = thumb if thumb
      thumb
    end

    def render_lora_content
      family = current_model_family
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      muted = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)

      # Header: show current model family filter
      header_parts = []
      if family
        family_info = MODEL_FAMILIES[family]
        family_label = family_info ? family_info[:label] : family
        header_parts << Lipgloss::Style.new.foreground(Theme.WARNING).render("Family: #{family_label}")
      else
        header_parts << muted.render("No model selected \u2014 showing all LoRAs")
      end

      # Active LoRA stack summary
      if @selected_loras.any?
        stack = @selected_loras.map { |l| "#{l[:name]}:#{l[:weight]}" }.join(", ")
        header_parts << Lipgloss::Style.new.foreground(Theme.SUCCESS).render("Active: #{stack}")
      end

      header = header_parts.join("  \u2502  ")

      if @available_loras.empty? && (@incompatible_loras || []).empty?
        return "#{header}\n#{dim.render("No LoRAs found in #{@lora_dir}")}"
      end

      if @available_loras.empty?
        incompat_count = (@incompatible_loras || []).length
        return "#{header}\n#{dim.render("No compatible LoRAs for #{family}")}\n#{muted.render("#{incompat_count} incompatible LoRA(s) hidden")}"
      end

      # LoRA list
      lines = @available_loras.each_with_index.map do |lora, i|
        sel = @selected_loras.find { |l| l[:path] == lora[:path] }
        selected = i == @lora_index
        meta = lora_metadata(lora)

        check = if sel
          Lipgloss::Style.new.foreground(Theme.SUCCESS).render("[x]")
        else
          Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("[ ]")
        end

        weight = if @editing_lora_weight && selected
          Lipgloss::Style.new.foreground(Theme.ACCENT).render(" w:#{@lora_weight_buffer}_")
        elsif sel
          Lipgloss::Style.new.foreground(Theme.ACCENT).render(" w:#{sel[:weight]}")
        else
          ""
        end

        # Family badge
        lora_fam = lora[:family]
        fam_badge = if lora_fam
          Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).render(" [#{lora_fam}]")
        else
          Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).render(" [?]")
        end

        # Type badge
        type_badge = if meta[:lora_type]
          Lipgloss::Style.new.foreground(Theme.SECONDARY).render(" #{LORA_TYPE_LABELS[meta[:lora_type]] || meta[:lora_type]}")
        else
          ""
        end

        line = if selected
          cursor = Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true).render("> ")
          name = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true).render(lora[:name])
          "#{cursor}#{check} #{name}#{fam_badge}#{type_badge}#{weight}"
        else
          "  #{check} #{lora[:name]}#{fam_badge}#{type_badge}#{weight}"
        end

        # Expanded card for selected LoRA
        if selected && @lora_card_expanded && meta[:desc]
          line += render_lora_card(lora, meta)
        elsif selected && meta[:desc]
          line += "\n     #{dim.render(meta[:desc])}"
        end

        line
      end

      # Show count of hidden incompatible LoRAs
      incompat_note = if (@incompatible_loras || []).any?
        "\n#{muted.render("\u2500" * 30)}\n#{muted.render("#{@incompatible_loras.length} incompatible LoRA(s) hidden (different family)")}"
      else
        ""
      end

      "#{header}\n#{lines.join("\n")}#{incompat_note}"
    end

    def render_lora_card(lora, meta)
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      muted = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
      accent = Lipgloss::Style.new.foreground(Theme.ACCENT)
      success = Lipgloss::Style.new.foreground(Theme.SUCCESS)
      pad = "     "

      card = +"\n"
      card << "#{pad}#{dim.render("\u250C" + "\u2500" * 40 + "\u2510")}\n"

      # Name and type
      type_label = meta[:lora_type] ? (LORA_TYPE_LABELS[meta[:lora_type]] || meta[:lora_type].to_s) : "Unknown"
      card << "#{pad}#{dim.render("\u2502")} #{accent.render("Type:")} #{type_label.to_s.ljust(33)}#{dim.render("\u2502")}\n"

      # Use for / Avoid
      if meta[:use_for]
        card << "#{pad}#{dim.render("\u2502")} #{success.render("Use:")}  #{meta[:use_for][0..32].ljust(33)}#{dim.render("\u2502")}\n"
      end
      if meta[:avoid]
        card << "#{pad}#{dim.render("\u2502")} #{Lipgloss::Style.new.foreground(Theme.ERROR).render("Avoid:")} #{meta[:avoid][0..30].ljust(31)}#{dim.render("\u2502")}\n"
      end

      # Weight range
      if meta[:recommended_weight]
        w = meta[:recommended_weight]
        card << "#{pad}#{dim.render("\u2502")} #{accent.render("Weight:")} #{w[:min]}\u2013#{w[:max]} (default: #{w[:default]})#{" " * [0, 18 - "#{w[:min]}-#{w[:max]} (default: #{w[:default]})".length].max}#{dim.render("\u2502")}\n"
      end

      # Description
      if meta[:desc]
        card << "#{pad}#{dim.render("\u2502")} #{muted.render(meta[:desc][0..38].ljust(39))}#{dim.render("\u2502")}\n"
      end

      # Tags
      if meta[:tags]&.any?
        tags_str = meta[:tags].join(", ")[0..38]
        card << "#{pad}#{dim.render("\u2502")} #{dim.render("Tags: #{tags_str}").to_s[0..38].ljust(39)}#{dim.render("\u2502")}\n"
      end

      card << "#{pad}#{dim.render("\u2514" + "\u2500" * 40 + "\u2518")}"
      card
    end

    def render_lora_status
      if @editing_lora_weight
        "enter: confirm | esc: cancel"
      else
        "space: toggle | i: details | +/-: weight | w: edit | d: download | esc: close"
      end
    end

    def render_preset_content
      all = all_presets
      if all.empty?
        return Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("No presets")
      end

      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)

      lines = all.each_with_index.map do |p, i|
        selected = i == @preset_index
        d = p[:data]
        tag = p[:builtin] ?
          Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).render(" built-in") :
          Lipgloss::Style.new.foreground(Theme.SUCCESS).render(" custom")

        # Friendly description from preset data, or fall back to technical details
        friendly = d['desc']
        tech_parts = []
        if d['model']
          tech_parts << File.basename(d['model'], File.extname(d['model']))
        elsif d['model_type']
          tech_parts << d['model_type'].upcase
        end
        tech_parts << "#{d['steps']} steps" if d['steps']
        tech_parts << "#{d['width']}x#{d['height']}" if d['width'] && d['height']
        tech_parts << "str:#{d['strength']}" if d['strength']
        tech = dim.render(tech_parts.join(" / "))

        desc_line = friendly ? Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render(friendly) : ""

        if selected
          cursor = Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true).render("> ")
          name = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true).render(p[:name])
          result = "#{cursor}#{name}#{tag}"
          result += "\n    #{desc_line}" if friendly
          result += "\n    #{tech}" unless tech_parts.empty?
          result
        else
          name = Lipgloss::Style.new.foreground(Theme.TEXT).render(p[:name])
          result = "  #{name}#{tag}"
          result += "\n    #{desc_line}" if friendly
          result
        end
      end

      result = lines.join("\n")
      if @naming_preset
        prompt_style = Lipgloss::Style.new.foreground(Theme.ACCENT)
        result += "\n\n#{prompt_style.render("Name:")} #{@preset_name_buffer}_"
      elsif @confirm_delete_preset
        warn_style = Lipgloss::Style.new.foreground(Theme.ERROR).bold(true)
        result += "\n\n#{warn_style.render("Delete this preset?")} #{dim.render("y/n")}"
      end
      result
    end

    def render_preset_status
      if @naming_preset
        "enter: save | esc: cancel"
      elsif @confirm_delete_preset
        "y: confirm | any: cancel"
      else
        "enter: load | s: save | d: delete | esc: close"
      end
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
        ["^u", "Clear init image + mask"],
        ["^e", "Open last image in viewer"],
        ["^f", "Fullscreen image preview"],
      ]],
      ["Mask (on mask param)", [
        ["g", "Auto-generate center-preserve mask"],
        ["p", "Open mask painter (click to paint)"],
        ["x", "Clear mask"],
      ]],
      ["Prompt AI", [
        ["alt+e", "Enhance prompt (add detail, quality tags)"],
        ["alt+n", "Auto-generate negative prompt"],
        ["alt+r", "Generate random creative prompt"],
      ]],
      ["App", [
        ["F1", "Toggle this help"],
        ["^q", "Quit"],
      ]],
    ].freeze

    def render_help_view
      @help_scroll ||= 0
      key_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      section_style = Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true)
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)

      lines = []
      HELP_SECTIONS.each_with_index do |(section_name, keys), si|
        lines << "" if si > 0
        lines << section_style.render(section_name)
        lines << dim.render("\u2500" * (section_name.length + 2))
        keys.each do |k, d|
          lines << "  #{key_style.render(k.ljust(12))} #{desc_style.render(d)}"
        end
      end

      # Scrollable content
      visible_h = @height - 6
      max_scroll = [lines.length - visible_h, 0].max
      @help_scroll = @help_scroll.clamp(0, max_scroll)
      visible = lines[@help_scroll, visible_h] || []

      scroll_hint = if max_scroll > 0
        pos = @help_scroll > 0 ? "\u2191" : " "
        pos += @help_scroll < max_scroll ? "\u2193" : " "
        dim.render("  #{pos} scroll with j/k")
      else
        ""
      end

      title_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      separator = dim.render("\u2500" * (@width - 6))
      body_content = "#{title_style.render("Keyboard Shortcuts")}\n#{separator}\n#{visible.join("\n")}"

      body = Lipgloss::Style.new
        .border(:rounded).border_foreground(Theme.PRIMARY).background(Theme.SURFACE)
        .width(@width - 4).height(@height - 4).padding(0, 1).render(body_content)

      status_text = "j/k: scroll | esc: close#{scroll_hint}"
      key_s = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).bold(true)
      desc_s = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
      status = Lipgloss::Style.new.width(@width).padding(0, 1).background(Theme.SURFACE)
        .render(format_help_text(status_text, key_s, desc_s))

      Lipgloss.join_vertical(:left, body, status)
    end

    def render_theme_content
      lines = THEME_NAMES.each_with_index.map do |name, i|
        theme = THEMES[name]
        selected = i == @theme_index
        badge = BUILTIN_THEMES.key?(name) ? "" : Lipgloss::Style.new.foreground(Theme.SUCCESS).render(" custom")

        # Color swatch: show key colors as colored blocks
        swatch = [
          theme["primary"], theme["secondary"], theme["accent"],
          theme["success"], theme["warning"], theme["error"],
        ].map { |c| Lipgloss::Style.new.foreground(c).render("\u2588\u2588") }.join(" ")

        if selected
          cursor = Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true).render("> ")
          label = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true).render(name)
          "#{cursor}#{label}#{badge}\n    #{swatch}"
        else
          dim_label = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render(name)
          "  #{dim_label}#{badge}\n    #{swatch}"
        end
      end

      lines.join("\n")
    end

    def render_theme_status
      "up/down: browse (live preview) | enter: apply | esc: cancel"
    end

    def render_provider_content
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      lines = @providers.each_with_index.map do |prov, i|
        selected = i == @provider_index
        active = prov.id == @provider.id

        # Status indicator
        status = if prov.needs_api_key?
          if prov.api_key_set?
            Lipgloss::Style.new.foreground(Theme.SUCCESS).render(" \u2713")
          else
            hint = selected ? " \u2014 press s to set key" : ""
            Lipgloss::Style.new.foreground(Theme.ERROR).render(" \u2717 no key#{hint}")
          end
        else
          Lipgloss::Style.new.foreground(Theme.SUCCESS).render(" \u2713")
        end

        active_badge = active ? Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true).render(" [active]") : ""

        name = if selected
          cursor = Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true).render("> ")
          label = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true).render(prov.display_name)
          "#{cursor}#{label}#{status}#{active_badge}"
        else
          "  #{dim.render(prov.display_name)}#{status}#{active_badge}"
        end

        # Show model selector for API providers when selected
        model_line = if selected && prov.provider_type == :api && prov.list_models.any?
          models = prov.list_models
          current_id = @remote_model_id || models.first[:id]
          cur_model = models.find { |m| m[:id] == current_id } || models.first
          arrow = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
          model_name = Lipgloss::Style.new.foreground(Theme.TEXT).render(cur_model[:name])
          model_desc = dim.render(" - #{cur_model[:desc]}")
          "\n    #{dim.render("Model:")} #{arrow.render("<")} #{model_name} #{arrow.render(">")}#{model_desc}"
        else
          ""
        end

        "#{name}#{model_line}"
      end

      lines.join("\n\n")
    end

    def render_provider_status
      "up/down: select | left/right: model | s: set key | enter: activate | esc: close"
    end

    def render_api_key_content
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      accent = Lipgloss::Style.new.foreground(Theme.ACCENT)
      prov = @provider

      lines = []
      lines << dim.render("#{prov.display_name} requires an API key to generate images.")
      lines << ""
      if prov.api_key_setup_url
        lines << dim.render("1. Go to  ") + accent.render(prov.api_key_setup_url)
        lines << dim.render("2. Create a new API key")
        lines << dim.render("3. Paste it below")
      else
        lines << dim.render("1. Set ") + accent.render(prov.api_key_env_var) + dim.render(" environment variable")
        lines << dim.render("   or paste your key below")
      end
      lines << ""
      lines << "Key: #{@api_key_input.view}"
      lines << ""
      lines << dim.render("Saved to ~/.config/chewy/keys/ (chmod 600)")
      lines << ""
      lines << dim.render("You can also set ") + accent.render(prov.api_key_env_var) + dim.render(" in your shell instead.")
      lines.join("\n")
    end

    def render_api_key_status
      "^v: paste from clipboard | enter: save | esc: cancel"
    end

    def render_hf_token_content
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      accent = Lipgloss::Style.new.foreground(Theme.ACCENT)

      lines = []
      lines << dim.render("FLUX models require a HuggingFace token to download companion files.")
      lines << ""
      lines << dim.render("1. Go to  ") + accent.render("huggingface.co/settings/tokens")
      lines << dim.render("2. Create a token (read access is enough)")
      lines << dim.render("3. Accept FLUX model terms at")
      lines << "   " + accent.render("huggingface.co/black-forest-labs/FLUX.1-schnell")
      lines << dim.render("4. Paste your token below")
      lines << ""
      lines << "Token: #{@hf_token_input.view}"
      lines << ""
      lines << dim.render("Saved to ~/.cache/huggingface/token")
      lines.join("\n")
    end

    def render_hf_token_status
      "enter: save | esc: cancel"
    end

    def render_file_picker_view
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      accent = Lipgloss::Style.new.foreground(Theme.ACCENT)
      dir_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      file_style = Lipgloss::Style.new.foreground(Theme.TEXT)
      selected_style = Lipgloss::Style.new.foreground(Theme.ACCENT).bold(true)
      title_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)

      if @file_picker_entries.empty?
        content = dim.render("No image files found in #{@file_picker_dir}")
        return render_overlay_panel("Select Image", content, "esc: close")
      end

      inner_h = @height - 6
      list_w = narrow? ? @width - 4 : [(@width * 0.4).to_i, 30].max
      preview_w = narrow? ? 0 : @width - list_w - 8

      # -- Left: file list --
      dir_label = @file_picker_dir
      max_dir_len = list_w - 4
      dir_label = "..." + dir_label[-(max_dir_len - 3)..] if dir_label.length > max_dir_len

      list_lines = [accent.render(dir_label), ""]

      if @init_image_path
        list_lines << dim.render("Current: ") + file_style.render(File.basename(@init_image_path))
        list_lines << ""
      end

      header_h = list_lines.length
      visible_h = inner_h - header_h - 4
      visible = @file_picker_entries[@file_picker_scroll, visible_h] || []

      visible.each_with_index do |entry, i|
        actual_i = @file_picker_scroll + i
        selected = actual_i == @file_picker_index
        cursor = selected ? selected_style.render("> ") : "  "

        if entry[:type] == :dir
          name = selected ? selected_style.render(entry[:name]) : dir_style.render(entry[:name])
          list_lines << "#{cursor}#{name}"
        else
          name_str = selected ? selected_style.render(entry[:name]) : file_style.render(entry[:name])
          size_str = dim.render("  #{format_bytes(entry[:size] || 0)}")
          list_lines << "#{cursor}#{name_str}#{size_str}"
        end
      end

      if @file_picker_entries.length > visible_h
        list_lines << ""
        list_lines << dim.render("#{@file_picker_index + 1}/#{@file_picker_entries.length}")
      end

      list_content = list_lines.join("\n")
      list_panel = Lipgloss::Style.new
        .border(:rounded).border_foreground(Theme.PRIMARY).background(Theme.SURFACE)
        .width(list_w).height(inner_h).padding(0, 1)
        .render(list_content)

      if narrow?
        body = list_panel
      else
        # -- Right: preview (async — thumbnail loaded in background thread) --
        entry = @file_picker_entries[@file_picker_index]
        center_in_preview = ->(s) {
          pad_top = [(inner_h - 4) / 2, 0].max
          centered = Lipgloss::Style.new.width(preview_w - 4).align(:center).render(s)
          (Array.new(pad_top, "") << centered).join("\n")
        }
        preview_content = if !@file_picker_preview_ready
          center_in_preview.call(dim.render("Loading..."))
        elsif entry && entry[:type] == :file && @file_picker_target != :cn_model
          thumb = if @kitty_graphics
            render_image(entry[:path], preview_w - 4, inner_h - 4, kitty_overlay: true)
          else
            @file_picker_thumb_cache[entry[:path]]
          end
          if thumb
            info = dim.render(entry[:name])
            thumb + "\n" + info
          else
            center_in_preview.call(dim.render("Loading..."))
          end
        elsif entry && entry[:type] == :file && @file_picker_target == :cn_model
          size_str = format_bytes(entry[:size] || 0)
          "#{dim.render(entry[:name])}\n#{dim.render(size_str)}"
        elsif entry && entry[:type] == :dir
          dim.render("Directory")
        else
          dim.render("(no preview)")
        end

        preview_panel = Lipgloss::Style.new
          .border(:rounded).border_foreground(Theme.BORDER_DIM).background(Theme.SURFACE)
          .width(preview_w).height(inner_h).padding(0, 1)
          .render(preview_content)

        body = Lipgloss.join_horizontal(:top, list_panel, preview_panel)

        # Register kitty overlay for file picker thumbnail (only when preview is ready)
        if @file_picker_preview_ready && @kitty_graphics && entry && entry[:type] == :file && @file_picker_target != :cn_model && File.exist?(entry[:path])
          picker_img_row = 1 + 1 + 1 + 1
          picker_img_col = 2 + 1 + list_w + 1 + 1
          @kitty_overlay_pending = { path: entry[:path], row: picker_img_row, col: picker_img_col, w: preview_w - 4, h: inner_h - 4, slot: 22 }
        end
      end

      picker_title = case @file_picker_target
      when :cn_model then "Select ControlNet Model"
      when :controlnet then "Select ControlNet Image"
      else "Select Image"
      end
      title_bar = title_style.render(picker_title)
      outer = Lipgloss::Style.new.padding(0, 1).render(
        Lipgloss.join_vertical(:left, title_bar, body)
      )

      status_text = "enter: select | backspace: up dir | ~: home | j/k: navigate | esc: cancel"
      key_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).bold(true)
      desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
      status = Lipgloss::Style.new.width(@width).padding(0, 1).background(Theme.SURFACE)
        .render(format_help_text(status_text, key_style, desc_style))

      Lipgloss.join_vertical(:left, outer, status)
    end

    def file_picker_thumb(path, max_w, max_h)
      return render_image(path, max_w, max_h, kitty_overlay: true) if @kitty_graphics

      cached = @file_picker_thumb_cache[path]
      return cached if cached

      @file_picker_thumb_cache.shift if @file_picker_thumb_cache.size >= 10

      thumb = render_image(path, max_w, max_h)
      @file_picker_thumb_cache[path] = thumb if thumb
      thumb
    end

    # ========== ControlNet Download Overlay ==========

    def render_cn_download_content
      if @model_downloading
        return "#{@spinner.view} #{Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("Downloading #{@download_filename}...")}"
      end
      return Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("Loading...") unless @cn_download_list
      @cn_download_list.view
    end

    def render_cn_download_status
      if @model_downloading
        current = (File.size(@download_dest) rescue 0)
        pct = @download_total > 0 ? (current.to_f / @download_total) : 0
        bar = @progress.view_as(pct.clamp(0.0, 1.0))
        size_text = @download_total > 0 ?
          "#{format_bytes(current)} / #{format_bytes(@download_total)}" :
          format_bytes(current)
        return "#{@download_filename} #{bar} #{size_text}"
      end
      "enter: download | esc: back"
    end

    # ========== Mask Painter Overlay ==========

    # ========== Starter Pack Overlay ==========

    def render_starter_pack_view
      title_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      accent = Lipgloss::Style.new.foreground(Theme.ACCENT)
      separator = dim.render("\u2500" * (@width - 6))

      if @starter_pack_downloading
        current_bytes = (File.size(@starter_pack_dest) rescue 0)
        file_pct = @starter_pack_download_size > 0 ? (current_bytes.to_f / @starter_pack_download_size) : 0
        bar = @progress.view_as(file_pct.clamp(0.0, 1.0))
        size_text = @starter_pack_download_size > 0 ?
          "#{format_bytes(current_bytes)} / #{format_bytes(@starter_pack_download_size)}" :
          format_bytes(current_bytes)

        content = [
          "#{@spinner.view} #{accent.render("Downloading starter pack...")}",
          "",
          "#{dim.render("Item")} #{accent.render("#{@starter_pack_completed + 1}")} #{dim.render("of")} #{accent.render("#{@starter_pack_total}")}",
          "#{Lipgloss::Style.new.foreground(Theme.TEXT).bold(true).render(@starter_pack_current_file)}",
          "",
          "#{bar} #{dim.render(size_text)}",
        ].join("\n")
      else
        checked_indices = @starter_pack_selected || []
        lines = STARTER_PACKS.each_with_index.map do |pack, i|
          highlighted = i == @starter_pack_index
          checked = checked_indices.include?(i)
          check = checked ?
            Lipgloss::Style.new.foreground(Theme.SUCCESS).render("[x]") :
            Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render("[ ]")
          if highlighted
            cursor = accent.render("> ")
            name = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true).render(pack[:name])
            desc = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).render(pack[:desc])
            "#{cursor}#{check} #{name}\n     #{desc}"
          else
            name = Lipgloss::Style.new.foreground(Theme.TEXT).render(pack[:name])
            desc = dim.render(pack[:desc])
            "  #{check} #{name}\n     #{desc}"
          end
        end
        content = lines.join("\n\n")
      end

      welcome = Theme.gradient_text("Welcome to Chewy!", Theme.PRIMARY, Theme.ACCENT)
      subtitle = dim.render("Select packs with space, then enter to download:")
      body_content = "#{welcome}\n#{subtitle}\n#{separator}\n\n#{content}"

      body = Lipgloss::Style.new
        .border(:rounded).border_foreground(Theme.PRIMARY).background(Theme.SURFACE)
        .width(@width - 4).height(@height - 4).padding(0, 1).render(body_content)

      status_text = if @starter_pack_downloading
        "downloading... please wait"
      else
        "space: toggle | enter: download selected | s/esc: skip (download later with ^d)"
      end
      key_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).bold(true)
      desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
      status = Lipgloss::Style.new.width(@width).padding(0, 1).background(Theme.SURFACE)
        .render(format_help_text(status_text, key_style, desc_style))

      Lipgloss.join_vertical(:left, body, status)
    end

    def render_mask_painter_view
      return "" unless @mask_paint_grid && @mask_paint_grid_colors

      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      title_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      brush_label = @mask_paint_brush == :paint ? "PAINT (white=regenerate)" : "ERASE (black=keep)"
      brush_style = @mask_paint_brush == :paint ?
        Lipgloss::Style.new.foreground(Theme.WARNING).bold(true) :
        Lipgloss::Style.new.foreground(Theme.SUCCESS).bold(true)

      title_bar = "#{title_style.render("Mask Painter")}  #{brush_style.render(brush_label)}"

      # Render the grid: show image colors dimmed, with white overlay where masked
      lines = @mask_paint_rows.times.map do |row|
        line = +""
        @mask_paint_cols.times do |col|
          if @mask_paint_grid[row][col]
            # Masked (white = regenerate) — show bright white block
            line << "\e[48;2;255;255;255m \e[0m"
          else
            # Unmasked (keep) — show image color dimmed
            r, g, b = @mask_paint_grid_colors[row][col]
            # Dim the color to show it's "kept"
            r = (r * 0.5).to_i; g = (g * 0.5).to_i; b = (b * 0.5).to_i
            line << "\e[48;2;#{r};#{g};#{b}m \e[0m"
          end
        end
        line
      end

      grid_content = lines.join("\n")

      body_content = "#{title_bar}\n\n#{grid_content}"
      body = Lipgloss::Style.new
        .border(:rounded).border_foreground(Theme.PRIMARY).background(Theme.SURFACE)
        .width(@width - 4).height(@height - 4).padding(0, 1).render(body_content)

      status_text = "click: paint | b: toggle brush | i: invert | c: clear | f: fill | enter: confirm | esc: cancel"
      key_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM).bold(true)
      desc_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED)
      status = Lipgloss::Style.new.width(@width).padding(0, 1).background(Theme.SURFACE)
        .render(format_help_text(status_text, key_style, desc_style))

      Lipgloss.join_vertical(:left, body, status)
    end
  end
end
