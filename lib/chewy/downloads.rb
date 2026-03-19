# frozen_string_literal: true

class Chewy
  module Downloads
    private

    def enter_download_mode
      case @focus
      when FOCUS_PROMPT then @prompt_input.blur
      when FOCUS_NEGATIVE then @negative_input.blur
      end
      @overlay = :download; @download_view = :recommended
      @error_message = nil; @fetching = false
      @download_search_input.value = "gguf"
      @download_search_input.blur
      @download_search_focused = false
      build_recommended_list
      [self, nil]
    end

    def build_recommended_list
      items = []
      items << { title: "Starter Packs...", description: "Curated bundles — models, LoRAs, ControlNet in one click" }
      PRELOADED_MODELS.each do |m|
        already = File.exist?(File.join(@models_dir, m[:file]))
        status = already ? " (installed)" : ""
        items << { title: "#{m[:name]}#{status}", description: "#{m[:type]} | #{format_bytes(m[:size])} \u2014 #{m[:desc]}" }
      end
      items << { title: "Browse HuggingFace...", description: "Search HuggingFace for GGUF and safetensors models" }
      items << { title: "Browse CivitAI...", description: "Search CivitAI for community models and checkpoints" }
      @recommended_list = Bubbles::List.new(items, width: @width - 12, height: [@height - 10, 6].max)
      @recommended_list.show_title = false
      @recommended_list.show_status_bar = false
      @recommended_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      @recommended_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    end

    def enter_hf_search_mode
      @download_view = :repos
      @download_source = :huggingface
      @error_message = nil; @fetching = true
      @download_search_input.value = "gguf"
      @download_search_input.placeholder = "Search HuggingFace models..."
      @download_search_input.focus
      @download_search_focused = true
      [self, fetch_repos_cmd("gguf")]
    end

    def enter_civitai_search_mode
      @download_view = :repos
      @download_source = :civitai
      @error_message = nil; @fetching = false
      @download_search_input.value = ""
      @download_search_input.placeholder = "Search CivitAI models..."
      @download_search_input.focus
      @download_search_focused = true
      @repo_list = nil
      [self, nil]
    end

    def fetch_civitai_models_cmd(query, type: "Checkpoint")
      Proc.new do
        params = "sort=Most+Downloaded&limit=50"
        params += "&types=#{type}" if query.empty?  # types filter only works without query
        params += "&query=#{URI.encode_www_form_component(query)}" unless query.empty?
        uri = URI.parse("#{CIVITAI_API_BASE}/models?#{params}")
        data = JSON.parse(hf_get(uri).body)
        models = (data["items"] || []).map do |m|
          latest = m["modelVersions"]&.first
          files = (latest&.dig("files") || []).select { |f|
            name = f["name"].downcase
            name.end_with?(".safetensors") || name.end_with?(".gguf") || name.end_with?(".ckpt")
          }
          {
            id: m["id"], name: m["name"], type: m["type"],
            downloads: m["stats"]&.dig("downloadCount") || 0,
            rating: m["stats"]&.dig("rating")&.round(1),
            version_name: latest&.dig("name"),
            base_model: latest&.dig("baseModel"),
            files: files.map { |f| { name: f["name"], size: f["sizeKB"]&.*(1024)&.to_i, url: f["downloadUrl"] } },
          }
        end.select { |m| m[:files].any? && m[:type]&.upcase == type.upcase }.first(25)
        ReposFetchedMessage.new(repos: models)
      rescue => e
        ReposFetchErrorMessage.new(error: e.message)
      end
    end

    def exit_download_mode
      @overlay = nil; @download_view = :recommended; @fetching = false
      @download_source = :huggingface
      @repo_list = nil; @file_list = nil; @recommended_list = nil
      @remote_repos = []; @remote_files = []; @selected_repo_id = nil; @error_message = nil
      @civitai_models = []
      @download_search_input.blur; @download_search_focused = false
      case @focus
      when FOCUS_PROMPT then @prompt_input.focus
      when FOCUS_NEGATIVE then @negative_input.focus
      end
      [self, nil]
    end

    def sdcpp_compatible_repo?(repo)
      id = (repo["id"] || "").downcase
      tags = (repo["tags"] || []).map(&:downcase)
      # Reject known incompatible model families
      return false if INCOMPATIBLE_HF_PATTERNS.any? { |p| id.include?(p) || tags.any? { |t| t.include?(p) } }
      true
    end

    def fetch_repos_cmd(query = "gguf")
      search = URI.encode_www_form_component(query)
      Proc.new do
        uri = URI.parse("#{HF_API_BASE}/models?search=#{search}&sort=downloads&direction=-1&limit=50")
        all_repos = JSON.parse(hf_get(uri).body)
        repos = all_repos.select { |r| sdcpp_compatible_repo?(r) }.first(25)
        ReposFetchedMessage.new(repos: repos)
      rescue => e
        ReposFetchErrorMessage.new(error: e.message)
      end
    end

    def handle_repos_fetched(message)
      @fetching = false; @remote_repos = message.repos
      @download_search_input.blur
      @download_search_focused = false
      if @download_source == :civitai
        @civitai_models = message.repos
        items = message.repos.map do |m|
          base = m[:base_model] ? " | #{m[:base_model]}" : ""
          rating = m[:rating] ? " | #{m[:rating]}*" : ""
          { title: m[:name], description: "#{format_number(m[:downloads])} downloads#{base}#{rating}" }
        end
      else
        items = @remote_repos.map do |r|
          { title: r["id"], description: "#{format_number(r["downloads"] || 0)} downloads" }
        end
      end
      items = [{ title: "No models found", description: "Try a different search" }] if items.empty?
      @repo_list = Bubbles::List.new(items, width: @width - 4, height: @height - 9)
      @repo_list.title = ""
      @repo_list.show_status_bar = false
      @repo_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      @repo_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      [self, nil]
    end

    def fetch_files_cmd(repo_id)
      @fetching = true; @selected_repo_id = repo_id
      is_flux = repo_id.downcase.include?("flux")
      Proc.new do
        uri = URI.parse("#{HF_API_BASE}/models/#{repo_id}/tree/main")
        all = JSON.parse(hf_get(uri).body)
        model_files = all.select { |f|
          next false unless f["type"] == "file"
          next false unless MODEL_EXTENSIONS.any? { |ext| f["path"].end_with?(ext) }
          basename = File.basename(f["path"]).downcase
          # Filter out companion/auxiliary files and LoRAs
          next false if COMPANION_FILE_PATTERNS.any? { |p| basename.start_with?(p) }
          next false if basename =~ /\blora\b/i
          # FLUX repos: only GGUF works with sd.cpp
          next false if is_flux && !f["path"].end_with?(".gguf")
          true
        }
        # Sort: .gguf first (preferred by sd.cpp), then by size descending
        model_files.sort_by! { |f| [f["path"].end_with?(".gguf") ? 0 : 1, -(f["size"] || 0)] }
        FilesFetchedMessage.new(files: model_files, repo_id: repo_id)
      rescue => e
        FilesFetchErrorMessage.new(error: e.message)
      end
    end

    def handle_files_fetched(message)
      @fetching = false; @download_view = :files; @remote_files = message.files
      is_flux_repo = (@selected_repo_id || "").downcase.include?("flux")
      items = @remote_files.map do |f|
        size_str = f["size"] ? format_bytes(f["size"]) : "unknown"
        if f["path"].end_with?(".gguf")
          quant = File.basename(f["path"]).match(/[_-](Q\d[_\w]*|F16|F32)/i)&.captures&.first&.upcase
          label = quant ? "#{size_str} | #{quant}" : size_str
          { title: f["path"], description: label }
        else
          { title: f["path"], description: size_str }
        end
      end
      if items.empty?
        no_files_msg = is_flux_repo ? "No GGUF files found \u2014 FLUX needs GGUF format. Try a repo like second-state/FLUX.1-dev-GGUF" : "No .gguf or .safetensors files found"
        items = [{ title: "No compatible files", description: no_files_msg }]
      end
      @file_list = Bubbles::List.new(items, width: @width - 4, height: @height - 9)
      @file_list.title = ""
      @file_list.show_status_bar = false
      @file_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      @file_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      [self, nil]
    end

    def start_model_download(repo_id, filename, size)
      FileUtils.mkdir_p(@models_dir)
      dest = File.join(@models_dir, filename); part = "#{dest}.part"
      @model_downloading = true; @download_dest = part
      @download_total = size || 0; @download_filename = filename; @error_message = nil
      url = "#{HF_DOWNLOAD_BASE}/#{repo_id}/resolve/main/#{URI.encode_www_form_component(filename)}"
      Proc.new do
        _out, err, st = Open3.capture3("curl", "-fL", "-o", part, "-s",
          "-C", "-", "--retry", "5", "--retry-delay", "3", "--retry-all-errors",
          "--connect-timeout", "30", url)
        if st.success?
          File.rename(part, dest)
          ModelDownloadDoneMessage.new(path: dest, filename: filename)
        else
          # Keep .part file so resume works on next attempt
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

    def handle_download_done(message)
      @model_downloading = false; @download_dest = nil; @download_filename = ""
      @error_message = nil
      scan_models
      if @overlay == :cn_download
        return exit_cn_download
      end
      @overlay = :models
      [self, set_status_toast("Downloaded #{message.filename}")]
    end

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
        if idx == 0
          # Starter Packs
          @overlay = :starter_pack
          @starter_pack_selected = []
          return [self, nil]
        end
        model_idx = idx - 1  # offset for Starter Packs entry
        if model_idx < PRELOADED_MODELS.length
          m = PRELOADED_MODELS[model_idx]
          dest = File.join(@models_dir, m[:file])
          if File.exist?(dest)
            return [self, set_error_toast("#{m[:name]} is already installed")]
          end
          return [self, start_model_download(m[:repo], m[:file], m[:size])]
        elsif model_idx == PRELOADED_MODELS.length
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

    def enter_lora_download_mode
      @overlay = :lora_download; @lora_download_view = :recommended
      @error_message = nil; @fetching = false
      @lora_search_input.value = "lora safetensors"
      @lora_search_input.blur
      @lora_search_focused = false
      build_lora_recommended_list
      [self, nil]
    end

    def build_lora_recommended_list
      family = current_model_family
      # Filter recommended LoRAs by current model family (show all if no model selected)
      filtered = if family
        RECOMMENDED_LORAS.select { |l| l[:model_family] == family }
      else
        RECOMMENDED_LORAS
      end
      @lora_recommended_filtered = filtered

      items = filtered.map do |l|
        already = File.exist?(File.join(@lora_dir, l[:file]))
        status = already ? " (installed)" : ""
        type_label = l[:lora_type] ? " #{LORA_TYPE_LABELS[l[:lora_type]] || l[:lora_type]}" : ""
        { title: "#{l[:name]}#{status}", description: "#{l[:model_family]}#{type_label} | #{format_bytes(l[:size])} \u2014 #{l[:desc]}" }
      end

      if family && filtered.empty?
        items << { title: "No recommended LoRAs for #{family}", description: "Browse online to find compatible LoRAs" }
      end

      items << { title: "Browse HuggingFace...", description: "Search HuggingFace for LoRAs" }
      items << { title: "Browse CivitAI...", description: "Search CivitAI for community LoRAs" }
      @lora_recommended_list = Bubbles::List.new(items, width: @width - 12, height: [@height - 10, 6].max)
      @lora_recommended_list.show_title = false
      @lora_recommended_list.show_status_bar = false
      @lora_recommended_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      @lora_recommended_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
    end

    def exit_lora_download_mode
      @overlay = :lora; @lora_download_view = :recommended; @fetching = false
      @lora_repo_list = nil; @lora_file_list = nil; @lora_recommended_list = nil
      @lora_remote_repos = []; @lora_remote_files = []; @lora_selected_repo_id = nil; @error_message = nil
      @lora_search_input.blur; @lora_search_focused = false
      scan_loras
      [self, nil]
    end

    def enter_lora_hf_search_mode
      @lora_download_view = :repos
      @lora_download_source = :huggingface
      @error_message = nil; @fetching = true
      @lora_search_input.value = "lora safetensors"
      @lora_search_input.placeholder = "Search HuggingFace LoRAs..."
      @lora_search_input.focus
      @lora_search_focused = true
      [self, fetch_lora_repos_cmd("lora safetensors")]
    end

    def fetch_lora_repos_cmd(query = "lora safetensors")
      search = URI.encode_www_form_component(query)
      Proc.new do
        uri = URI.parse("#{HF_API_BASE}/models?search=#{search}&sort=downloads&direction=-1&limit=50")
        all_repos = JSON.parse(hf_get(uri).body)
        # Filter to repos that likely contain LoRA files
        repos = all_repos.select { |r|
          id = (r["id"] || "").downcase
          tags = (r["tags"] || []).map(&:downcase)
          id.include?("lora") || tags.include?("lora")
        }.first(25)
        LoraReposFetchedMessage.new(repos: repos)
      rescue => e
        LoraReposFetchErrorMessage.new(error: e.message)
      end
    end

    def handle_lora_repos_fetched(message)
      @fetching = false; @lora_remote_repos = message.repos
      @lora_search_input.blur
      @lora_search_focused = false
      if @lora_download_source == :civitai
        @lora_civitai_models = message.repos
        items = message.repos.map do |m|
          base = m[:base_model] ? " | #{m[:base_model]}" : ""
          rating = m[:rating] ? " | #{m[:rating]}*" : ""
          { title: m[:name], description: "#{format_number(m[:downloads])} downloads#{base}#{rating}" }
        end
      else
        items = @lora_remote_repos.map do |r|
          { title: r["id"], description: "#{format_number(r["downloads"] || 0)} downloads" }
        end
      end
      items = [{ title: "No LoRAs found", description: "Try a different search" }] if items.empty?
      @lora_repo_list = Bubbles::List.new(items, width: @width - 4, height: @height - 9)
      @lora_repo_list.title = ""
      @lora_repo_list.show_status_bar = false
      @lora_repo_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      @lora_repo_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      [self, nil]
    end

    def fetch_lora_files_cmd(repo_id)
      @fetching = true; @lora_selected_repo_id = repo_id
      Proc.new do
        uri = URI.parse("#{HF_API_BASE}/models/#{repo_id}/tree/main")
        all = JSON.parse(hf_get(uri).body)
        lora_files = all.select { |f|
          next false unless f["type"] == "file"
          f["path"].end_with?(".safetensors")
        }
        LoraFilesFetchedMessage.new(files: lora_files, repo_id: repo_id)
      rescue => e
        LoraFilesFetchErrorMessage.new(error: e.message)
      end
    end

    def handle_lora_files_fetched(message)
      @fetching = false; @lora_download_view = :files; @lora_remote_files = message.files
      items = @lora_remote_files.map { |f| { title: f["path"], description: f["size"] ? format_bytes(f["size"]) : "unknown" } }
      items = [{ title: "No .safetensors files found", description: "" }] if items.empty?
      @lora_file_list = Bubbles::List.new(items, width: @width - 4, height: @height - 9)
      @lora_file_list.title = ""
      @lora_file_list.show_status_bar = false
      @lora_file_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      @lora_file_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      [self, nil]
    end

    def start_lora_download(repo_id, filename, size)
      FileUtils.mkdir_p(@lora_dir)
      dest = File.join(@lora_dir, File.basename(filename)); part = "#{dest}.part"
      @lora_downloading = true; @lora_download_dest = part
      @lora_download_total = size || 0; @lora_download_filename = File.basename(filename); @error_message = nil
      url = "#{HF_DOWNLOAD_BASE}/#{repo_id}/resolve/main/#{URI.encode_www_form_component(filename)}"
      Proc.new do
        _out, err, st = Open3.capture3("curl", "-fL", "-o", part, "-s",
          "-C", "-", "--retry", "5", "--retry-delay", "3", "--retry-all-errors",
          "--connect-timeout", "30", url)
        if st.success?
          File.rename(part, dest)
          LoraDownloadDoneMessage.new(path: dest, filename: File.basename(filename))
        else
          LoraDownloadErrorMessage.new(error: "Download failed (exit #{st.exitstatus}). Try again to resume.")
        end
      rescue Errno::ENOENT
        File.delete(part) if File.exist?(part)
        LoraDownloadErrorMessage.new(error: "curl not found")
      rescue => e
        File.delete(part) rescue nil
        LoraDownloadErrorMessage.new(error: e.message)
      end
    end

    def show_lora_civitai_files(model)
      @lora_download_view = :files
      @lora_selected_repo_id = model[:name]
      @lora_civitai_selected_files = model[:files]
      items = model[:files].map do |f|
        { title: f[:name], description: f[:size] ? format_bytes(f[:size]) : "unknown" }
      end
      items = [{ title: "No compatible files", description: "" }] if items.empty?
      @lora_file_list = Bubbles::List.new(items, width: @width - 4, height: @height - 9)
      @lora_file_list.title = ""
      @lora_file_list.show_status_bar = false
      @lora_file_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      @lora_file_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      [self, nil]
    end

    def start_lora_civitai_download(filename, url, size)
      FileUtils.mkdir_p(@lora_dir)
      dest = File.join(@lora_dir, filename); part = "#{dest}.part"
      @lora_downloading = true; @lora_download_dest = part
      @lora_download_total = size || 0; @lora_download_filename = filename; @error_message = nil
      Proc.new do
        _out, err, st = Open3.capture3("curl", "-fL", "-o", part, "-s",
          "-C", "-", "--retry", "5", "--retry-delay", "3", "--retry-all-errors",
          "--connect-timeout", "30", url)
        if st.success?
          File.rename(part, dest)
          LoraDownloadDoneMessage.new(path: dest, filename: filename)
        else
          LoraDownloadErrorMessage.new(error: "Download failed (exit #{st.exitstatus}). Try again to resume.")
        end
      rescue Errno::ENOENT
        File.delete(part) if File.exist?(part)
        LoraDownloadErrorMessage.new(error: "curl not found")
      rescue => e
        File.delete(part) rescue nil
        LoraDownloadErrorMessage.new(error: e.message)
      end
    end

    def handle_lora_download_done(message)
      @lora_downloading = false; @lora_download_dest = nil; @lora_download_filename = ""
      @error_message = nil
      scan_loras
      @overlay = :lora
      [self, set_status_toast("Downloaded #{message.filename}")]
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

    # ========== ControlNet Download ==========

    def enter_controlnet_download
      family = current_model_family
      filtered = if family
        RECOMMENDED_CONTROLNETS.select { |c| c[:model_family] == family }
      else
        RECOMMENDED_CONTROLNETS
      end
      @cn_download_list_data = filtered

      items = filtered.map do |c|
        already = File.exist?(File.join(@models_dir, c[:file]))
        status = already ? " (installed)" : ""
        { title: "#{c[:name]}#{status}", description: "#{format_bytes(c[:size])} — #{c[:desc]}" }
      end
      items = [{ title: "No ControlNet models for #{family}", description: "Try a different base model" }] if items.empty?

      @cn_download_list = Bubbles::List.new(items, width: @width - 12, height: [@height - 10, 6].max)
      @cn_download_list.show_title = false
      @cn_download_list.show_status_bar = false
      @cn_download_list.selected_item_style = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      @cn_download_list.item_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)

      @overlay = :cn_download
      @error_message = nil
      [self, nil]
    end

    def handle_cn_download_key(message)
      key = message.to_s
      return exit_cn_download if key == "esc" || key == "q"
      return [self, nil] if @model_downloading

      if key == "enter" && @cn_download_list
        idx = @cn_download_list.selected_index rescue 0
        filtered = @cn_download_list_data || []
        if idx < filtered.length
          c = filtered[idx]
          dest = File.join(@models_dir, c[:file])
          if File.exist?(dest)
            return [self, set_error_toast("#{c[:name]} is already installed")]
          end
          return [self, start_model_download(c[:repo], c[:file], c[:size])]
        end
        return [self, nil]
      end

      @cn_download_list, cmd = @cn_download_list.update(message)
      [self, cmd]
    end

    def start_controlnet_download(repo_id, hf_filename, local_filename, size)
      FileUtils.mkdir_p(@models_dir)
      dest = File.join(@models_dir, local_filename); part = "#{dest}.part"
      @model_downloading = true; @download_dest = part
      @download_total = size || 0; @download_filename = local_filename; @error_message = nil
      url = "#{HF_DOWNLOAD_BASE}/#{repo_id}/resolve/main/#{URI.encode_www_form_component(hf_filename)}"
      Proc.new do
        _out, err, st = Open3.capture3("curl", "-fL", "-o", part, "-s",
          "-C", "-", "--retry", "5", "--retry-delay", "3", "--retry-all-errors",
          "--connect-timeout", "30", url)
        if st.success?
          File.rename(part, dest)
          ModelDownloadDoneMessage.new(path: dest, filename: local_filename)
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

    # ========== Starter Pack Downloads ==========

    def start_starter_pack_download(index)
      start_starter_pack_download_multi([index])
    end

    def start_starter_pack_download_multi(indices)
      # Merge items from all selected packs, deduplicate by file
      all_items = indices.flat_map do |i|
        pack = STARTER_PACKS[i]
        resolve_starter_pack_items(pack)
      end
      items = all_items.uniq { |item| item[:file] }
      items = items.reject { |item| starter_pack_item_installed?(item) }

      if items.empty?
        return [self, set_status_toast("Everything already installed!")]
      end

      @starter_pack_downloading = true
      @starter_pack_queue = items
      @starter_pack_total = items.length
      @starter_pack_completed = 0
      @starter_pack_errors = []

      start_next_starter_pack_item
    end

    def resolve_starter_pack_items(pack)
      return expand_all_starter_items if pack[:items] == :all
      pack[:items]
    end

    def expand_all_starter_items
      items = []
      PRELOADED_MODELS.each { |m| items << { type: :model, repo: m[:repo], file: m[:file], size: m[:size] } }
      RECOMMENDED_LORAS.each { |l| items << { type: :lora, repo: l[:repo], file: l[:file], size: l[:size] } }
      RECOMMENDED_CONTROLNETS.each { |c| items << { type: :controlnet, repo: c[:repo], file: c[:file], size: c[:size] } }
      items
    end

    def starter_pack_item_installed?(item)
      dir = case item[:type]
            when :model, :controlnet then @models_dir
            when :lora then @lora_dir
            end
      File.exist?(File.join(dir, File.basename(item[:file])))
    end

    def start_next_starter_pack_item
      if @starter_pack_queue.empty?
        @starter_pack_downloading = false
        @starter_pack_current_file = ""
        @starter_pack_dest = nil
        scan_models
        scan_loras
        # Auto-select first available model
        @selected_model_path ||= @model_paths&.first
        update_param_keys
        @overlay = nil
        case @focus
        when FOCUS_PROMPT then @prompt_input.focus
        when FOCUS_NEGATIVE then @negative_input.focus
        end
        if @starter_pack_errors.empty?
          return [self, set_status_toast("Starter pack ready! You're all set to generate.")]
        else
          return [self, set_error_toast("Some downloads failed: #{@starter_pack_errors.join(', ')}")]
        end
      end

      item = @starter_pack_queue.shift
      dest_dir = case item[:type]
                 when :model, :controlnet then @models_dir
                 when :lora then @lora_dir
                 end
      FileUtils.mkdir_p(dest_dir)

      filename = File.basename(item[:file])
      dest = File.join(dest_dir, filename)
      part = "#{dest}.part"

      @starter_pack_current_file = filename
      @starter_pack_dest = part
      @starter_pack_download_size = item[:size] || 0

      # For controlnet models with hf_path, use that for the URL
      hf_file = item[:hf_path] || item[:file]
      url = "#{HF_DOWNLOAD_BASE}/#{item[:repo]}/resolve/main/#{URI.encode_www_form_component(hf_file)}"

      cmd = Proc.new do
        _out, err, st = Open3.capture3("curl", "-fL", "-o", part, "-s",
          "-C", "-", "--retry", "5", "--retry-delay", "3", "--retry-all-errors",
          "--connect-timeout", "30", url)
        if st.success?
          File.rename(part, dest)
          StarterPackItemDoneMessage.new(item_name: filename)
        else
          StarterPackItemErrorMessage.new(item_name: filename, error: "Download failed (exit #{st.exitstatus})")
        end
      rescue Errno::ENOENT
        File.delete(part) if File.exist?(part)
        StarterPackItemErrorMessage.new(item_name: filename, error: "curl not found")
      rescue => e
        File.delete(part) rescue nil
        StarterPackItemErrorMessage.new(item_name: filename, error: e.message)
      end

      [self, cmd]
    end

    def exit_cn_download
      was_downloading = @model_downloading
      @model_downloading = false
      @cn_download_list = nil; @cn_download_list_data = nil
      @overlay = nil; @error_message = nil
      scan_models
      # Auto-select the downloaded ControlNet model
      cn = RECOMMENDED_CONTROLNETS.find { |c| File.exist?(File.join(@models_dir, c[:file])) }
      if cn
        @controlnet_model_path = File.join(@models_dir, cn[:file])
        @controlnet_canny = cn[:use_canny]
        # Always sync control image to init image
        @controlnet_image_path = @init_image_path if @init_image_path
      end
      update_param_keys
      case @focus
      when FOCUS_PROMPT then @prompt_input.focus
      when FOCUS_NEGATIVE then @negative_input.focus
      end
      toast = cn ? set_status_toast("ControlNet ready: #{cn[:name]}") : nil
      [self, toast]
    end
  end
end
