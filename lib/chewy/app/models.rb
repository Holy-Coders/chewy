# frozen_string_literal: true

module Chewy::Models
  private

  def scan_models
    Dir.glob(File.join(@models_dir, "**", "*.part")).each { |f| File.delete(f) rescue nil }

    companion_names = FLUX_COMPANION_FILES.values.map { |v| v[:filename] }
    ext_glob = "*.{safetensors,gguf,ckpt}"

    # Scan primary dir + any extra app directories that exist
    dirs = [@models_dir] + EXTRA_MODEL_DIRS.select { |d| File.directory?(d) }
    files = dirs.flat_map { |d| Dir.glob(File.join(d, "**", ext_glob)) }
      .uniq
      .reject { |f| companion_names.include?(File.basename(f)) }
      .reject { |f| File.basename(f) =~ /\blora\b/i }   # LoRA weights, not diffusion models
      .reject { |f| File.size(f) < 100_000_000 }         # too small to be a diffusion model

    # Sort: pinned first, recent second, rest alphabetical
    pinned = files.select { |f| @pinned_models.include?(f) }
    recent = files.select { |f| @recent_models.include?(f) && !@pinned_models.include?(f) }
    rest = files - pinned - recent

    sorted = pinned + recent + rest

    @model_paths = sorted

    items = if sorted.empty?
      [{ title: "No models found", description: "Press d to download" }]
    else
      sorted.map do |f|
        name = File.basename(f)
        prefix = @pinned_models.include?(f) ? "* " : "  "
        source = model_source_tag(f)
        type_tag = model_type_tag(f)
        family = model_family_for(detect_model_type(f))
        family_tag = family ? " [#{family}]" : ""
        { title: "#{prefix}#{name}", description: "#{type_tag}#{family_tag}#{source}".strip }
      end
    end

    @model_list = Bubbles::List.new(items, width: @width - 12, height: [@height - 10, 6].max)
    @model_list.show_title = false
    @model_list.show_status_bar = false
    @model_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    @model_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)

    if sorted.any?
      preferred = if @selected_model_path && sorted.include?(@selected_model_path)
        @selected_model_path
      else
        last = @config["last_model"]
        last if last && sorted.include?(last)
      end

      @selected_model_path = preferred || sorted.first
      @model_list.select(sorted.index(@selected_model_path) || 0)
    end
  end

  def scan_api_models
    models = @provider.list_models
    @api_model_entries = models

    items = if models.empty?
      [{ title: "No models available", description: "" }]
    else
      models.map do |m|
        { title: "  #{m[:name]}", description: m[:desc] || "" }
      end
    end

    @model_list = Bubbles::List.new(items, width: @width - 12, height: [@height - 10, 6].max)
    @model_list.show_title = false
    @model_list.show_status_bar = false
    @model_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
    @model_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)

    # Select current model
    if models.any?
      cur = models.index { |m| m[:id] == @remote_model_id } || 0
      @model_list.select(cur)
    end
  end

  def model_type_tag(path)
    # Use cached type from previous validation if available
    if @model_types[path]
      return " | #{@model_types[path]}"
    end
    # Guess from filename
    name = File.basename(path).downcase
    type = if name.include?("flux")
      "FLUX"
    elsif name.include?("sdxl") || name.include?("sd_xl")
      "SDXL"
    elsif name.include?("sd3")
      "SD3"
    elsif name.include?("sd15") || name.include?("sd1.") || name.include?("sd_1") || name.include?("v1-")
      "SD 1.x"
    elsif name.include?("sd2") || name.include?("v2-")
      "SD 2.x"
    end
    type ? " | #{type}" : ""
  end

  def model_source_tag(path)
    if path.include?(".diffusionbee")
      " | DiffusionBee"
    elsif path.include?("draw-things")
      " | Draw Things"
    else
      ""
    end
  end

  def validate_model_cmd(path)
    sd_bin = @sd_bin
    Proc.new do
      # Run sd with 1 step at tiny resolution; kill early once we detect the version line
      args = [sd_bin, "-m", path, "-p", "test", "--steps", "1", "-W", "64", "-H", "64", "-o", "/dev/null"]
      r, _w, pid = PTY.spawn(*args)
      output = +""
      type = nil
      begin
        loop do
          chunk = r.readpartial(4096)
          output << chunk
          # Check for version detection
          if output.include?("Version:")
            type = if output.include?("Version: Flux")
              "FLUX"
            elsif output.include?("Version: SDXL")
              "SDXL"
            elsif output.include?("Version: SD 3")
              "SD3"
            elsif output.include?("Version: SD 2")
              "SD 2.x"
            elsif output.include?("Version: SD 1")
              "SD 1.x"
            end
            Process.kill("TERM", pid) rescue nil
            break
          end
        end
      rescue Errno::EIO, EOFError
        # Process ended before printing a detectable version line.
      end
      r.close rescue nil
      Process.wait(pid) rescue nil

      ModelValidatedMessage.new(path: path, model_type: type)
    rescue => e
      ModelValidatedMessage.new(path: path, error: e.message)
    end
  end

  def handle_model_validated(message)
    if message.model_type
      @model_types[message.path] = message.model_type
      save_config
      scan_models  # refresh list to show detected type
      filter_loras # re-filter LoRAs now that we know the model type
    end
    [self, nil]
  end

  def toggle_pin(path)
    if @pinned_models.include?(path)
      @pinned_models.delete(path)
    else
      @pinned_models << path
    end
    save_config
    scan_models
  end

  def add_recent_model(path)
    @recent_models.delete(path)
    @recent_models.unshift(path)
    @recent_models = @recent_models.first(5)
    save_config
  end

  def detect_model_type(path)
    return nil unless path
    # Prefer cached validated type
    return @model_types[path] if @model_types[path]
    # Guess from filename
    name = File.basename(path).downcase
    if name.include?("flux")
      "FLUX"
    elsif name.include?("sdxl") || name.include?("sd_xl")
      "SDXL"
    elsif name.include?("sd3")
      "SD3"
    elsif name.include?("sd15") || name.include?("sd1.") || name.include?("sd_1") || name.include?("v1-")
      "SD 1.x"
    elsif name.include?("sd2") || name.include?("v2-")
      "SD 2.x"
    end
  end

  # Resolve a model type string to its canonical MODEL_FAMILIES key
  def model_family_for(model_type)
    return nil unless model_type
    MODEL_FAMILY_LOOKUP[model_type.downcase] || model_type
  end

  # Get the model family for the currently selected model
  def current_model_family
    return nil unless @selected_model_path
    model_type = detect_model_type(@selected_model_path)
    model_family_for(model_type)
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
end
