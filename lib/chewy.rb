# frozen_string_literal: true

require "bubbletea"
require "lipgloss"
require "bubbles"
require "open3"
require "fileutils"
require "net/http"
require "json"
require "uri"
require "yaml"
require "chunky_png"
require "pty"
require "base64"
require "etc"

CHEWY_ROOT = File.expand_path("..", __dir__)

require_relative "chewy/constants"
require_relative "chewy/theme"
require_relative "chewy/messages"
require_relative "chewy/providers"
require_relative "chewy/config"
require_relative "chewy/models"
require_relative "chewy/loras"
require_relative "chewy/generation"
require_relative "chewy/input_handling"
require_relative "chewy/overlays"
require_relative "chewy/downloads"
require_relative "chewy/rendering"
require_relative "chewy/overlay_rendering"
require_relative "chewy/image_rendering"
require_relative "chewy/prompt_enhance"
require_relative "chewy/cli"

class Chewy
  include Bubbletea::Model
  include Config
  include Models
  include Loras
  include Generation
  include InputHandling
  include Overlays
  include Downloads
  include Rendering
  include OverlayRendering
  include ImageRendering
  include PromptEnhance

  def initialize
    @config = load_config
    @first_run = !File.exist?(CONFIG_PATH)
    Theme.set(@config["theme"] || "midnight")
    save_config if @first_run

    @width = 80; @height = 24
    @focus = FOCUS_PROMPT

    # Kitty graphics protocol support (Ghostty, Kitty, WezTerm)
    @kitty_graphics = %w[ghostty kitty WezTerm].any? { |t|
      ENV["TERM_PROGRAM"]&.downcase&.include?(t.downcase) || ENV["TERM"]&.include?(t.downcase)
    }
    @kitty_image_id = 0  # auto-incrementing image ID for kitty protocol
    @kitty_overlay_pending = nil  # {path:, row:, col:, w:, h:, slot:} set during view, processed after lipgloss

    # Models
    @models_dir = File.expand_path(ENV["CHEWY_MODELS_DIR"] || @config["model_dir"] || "~/.config/chewy/models")
    @selected_model_path = nil
    @model_list = nil
    @model_paths = []
    @pinned_models = @config["pinned_models"] || []
    @recent_models = @config["recent_models"] || []
    @incompatible_models = @config["incompatible_models"] || []
    @model_types = @config["model_types"] || {}  # path => "SD 1.x", "SDXL", "Flux", etc.

    # Prompt + Negative
    @prompt_input = Bubbles::TextInput.new
    @prompt_input.placeholder = "Describe your image..."
    @prompt_input.prompt = ""
    @prompt_input.placeholder_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).italic(true)
    @prompt_input.text_style = Lipgloss::Style.new.foreground(Theme.TEXT)
    @prompt_input.focus

    @negative_input = Bubbles::TextInput.new
    @negative_input.placeholder = "Negative prompt (optional)..."
    @negative_input.prompt = ""
    @negative_input.placeholder_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).italic(true)
    @negative_input.text_style = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)

    # Prompt history (seeded from on-disk generation history)
    @prompt_history = load_prompt_history_from_disk
    @history_index = -1
    @saved_prompt = ""

    # Params
    ds = @config["default_steps"] || 20
    dc = (@config["default_cfg"] || 7.0).to_f
    dw = @config["default_width"] || 512
    dh = @config["default_height"] || 512
    @params = { steps: ds, cfg_scale: dc, width: dw, height: dh, seed: -1, batch: 1, strength: 0.75,
                 guidance: (@config["default_guidance"] || 3.5).to_f,
                 threads: @config["default_threads"] || [Etc.nprocessors - 2, 1].max }
    @sampler = @config["default_sampler"] || "euler_a"
    @sampler_index = SAMPLER_OPTIONS.index(@sampler) || 1
    @scheduler = @config["default_scheduler"] || "discrete"
    @scheduler_index = SCHEDULER_OPTIONS.index(@scheduler) || 0
    @param_display_keys = %i[steps cfg_scale width height seed sampler scheduler batch strength threads]
    @param_index = 0
    @editing_param = false
    @param_edit_buffer = ""

    # Generation
    @generating = false
    @gen_pid = nil
    @gen_cancelled = false
    @gen_step = 0
    @gen_total_steps = 0
    @gen_current_batch = 0
    @gen_total_batch = 1
    @last_seed = nil
    @spinner = Bubbles::Spinner.new(spinner: Bubbles::Spinners::PULSE)
    @spinner.style = Lipgloss::Style.new.foreground(Theme.PRIMARY)
    @progress = Bubbles::Progress.new(width: 30, gradient: [Theme.PRIMARY, Theme.ACCENT])
    @last_output_path = nil
    @last_generation_time = nil
    @status_message = nil
    @status_generation = 0
    @first_run_toast = @first_run
    @error_message = nil
    @error_generation = 0

    # Paths
    bundled_sd = File.join(CHEWY_ROOT, "bin", "sd")
    @sd_bin = ENV["SD_BIN"] || @config["sd_bin"] || (File.executable?(bundled_sd) ? bundled_sd : "sd")
    @output_dir = File.expand_path(ENV["CHEWY_OUTPUT_DIR"] || @config["output_dir"] || "~/.config/chewy/outputs")
    @lora_dir = File.expand_path(ENV["CHEWY_LORA_DIR"] || @config["lora_dir"] || "~/.config/chewy/loras")

    # Providers
    @providers = build_providers
    @active_provider_id = @config["active_provider"] || "local_sd_cpp"
    @provider = @providers.find { |p| p.id == @active_provider_id } || @providers.first
    @provider_index = @providers.index(@provider) || 0
    @remote_model_id = @config["remote_model"] || nil
    @remote_model_index = 0

    # Overlay: nil, :models, :download, :lora, :preset, :hf_token, :gallery, :fullscreen_image, :file_picker, :theme, :provider
    @overlay = nil

    # img2img / ControlNet
    @init_image_path = nil
    @controlnet_model_path = nil
    @controlnet_image_path = nil
    @controlnet_strength = 0.9
    @controlnet_canny = false
    @mask_image_path = nil
    @file_picker_target = :init_image
    @file_picker_dir = File.expand_path("~")
    @file_picker_entries = []
    @file_picker_index = 0
    @file_picker_scroll = 0
    @file_picker_thumb_cache = {}
    @file_picker_preview_gen = 0      # debounce generation counter
    @file_picker_preview_ready = true # false while waiting for debounce tick

    # Gallery
    @gallery_images = []
    @gallery_index = 0
    @gallery_thumb_cache = {}
    @gallery_preview_gen = 0
    @gallery_preview_ready = true

    # Fullscreen image view
    @fullscreen_image_path = nil

    # HF token
    @hf_token_input = Bubbles::TextInput.new
    @hf_token_input.placeholder = "hf_..."
    @hf_token_input.prompt = ""
    @hf_token_input.placeholder_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).italic(true)
    @hf_token_input.text_style = Lipgloss::Style.new.foreground(Theme.TEXT)
    @hf_token_pending_action = nil

    # API key input (for remote providers)
    @api_key_input = Bubbles::TextInput.new
    @api_key_input.placeholder = "Paste your API key..."
    @api_key_input.prompt = ""
    @api_key_input.placeholder_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).italic(true)
    @api_key_input.text_style = Lipgloss::Style.new.foreground(Theme.TEXT)

    # Image preview cache
    @preview_cache = nil
    @preview_path = nil

    # Chip click map: [{y:, x_start:, x_end:, chip:, target: :prompt/:negative}]
    @chip_hit_map = []

    # Progressive reveal animation
    @reveal_phase = nil  # nil = no animation, 0-4 = progressive phases
    @reveal_path = nil

    # Live generation preview
    @gen_preview_path = nil
    @gen_preview_mtime = nil
    @gen_preview_cache = nil

    # Download browser
    @download_view = :recommended
    @download_source = :huggingface  # :huggingface or :civitai
    @remote_repos = []; @remote_files = []
    @repo_list = nil; @file_list = nil; @recommended_list = nil
    @selected_repo_id = nil
    @civitai_models = []  # cached CivitAI search results with version/file info
    @fetching = false
    @model_downloading = false
    @download_dest = nil; @download_total = 0; @download_filename = ""
    @download_search_input = Bubbles::TextInput.new
    @download_search_input.placeholder = "Search HuggingFace models..."
    @download_search_input.prompt = ""
    @download_search_input.placeholder_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).italic(true)
    @download_search_input.text_style = Lipgloss::Style.new.foreground(Theme.TEXT)
    @download_search_focused = false

    # LoRA
    @all_loras = []         # all scanned LoRAs (unfiltered)
    @available_loras = []   # LoRAs compatible with current model family
    @incompatible_loras = [] # LoRAs from other families (shown dimmed)
    @selected_loras = [] # [{name:, path:, weight:}]
    @lora_index = 0
    @editing_lora_weight = false
    @lora_weight_buffer = ""
    @lora_card_expanded = false # toggle detail card view

    # LoRA download
    @lora_download_view = :recommended
    @lora_download_source = :huggingface
    @lora_remote_repos = []; @lora_remote_files = []
    @lora_repo_list = nil; @lora_file_list = nil; @lora_recommended_list = nil
    @lora_selected_repo_id = nil
    @lora_civitai_models = []
    @lora_downloading = false
    @lora_download_dest = nil; @lora_download_total = 0; @lora_download_filename = ""
    @lora_search_input = Bubbles::TextInput.new
    @lora_search_input.placeholder = "Search HuggingFace LoRAs..."
    @lora_search_input.prompt = ""
    @lora_search_input.placeholder_style = Lipgloss::Style.new.foreground(Theme.TEXT_MUTED).italic(true)
    @lora_search_input.text_style = Lipgloss::Style.new.foreground(Theme.TEXT)
    @lora_search_focused = false

    # Presets
    @user_presets = load_presets
    @preset_index = 0
    @naming_preset = false
    @preset_name_buffer = ""
    @confirm_delete_preset = false

    # Confirmation flags for destructive actions
    @confirm_delete_model = nil
    @confirm_delete_gallery = nil

    # Best-settings confirmation after model selection / img2img
    @confirm_apply_best_settings = false
    @pending_best_settings_type = nil
    @pending_best_settings_img2img = false

    # FLUX companion downloads
    @companion_downloading = false
    @companion_remaining = 0
    @companion_errors = []
    @companion_current_file = ""
    @companion_dest = nil
    @companion_download_size = 0
    @companion_queue = []
    @companion_hf_token = nil

    # Theme picker
    @theme_index = THEME_NAMES.index(Theme.current_name) || 0
    @theme_original = Theme.current_name

    # Starter pack
    @starter_pack_index = 0
    @starter_pack_selected = []
    @starter_pack_downloading = false
    @starter_pack_queue = []
    @starter_pack_total = 0
    @starter_pack_completed = 0
    @starter_pack_errors = []
    @starter_pack_current_file = ""
    @starter_pack_dest = nil
    @starter_pack_download_size = 0

    # Prompt enhancement
    @prompt_enhancing = false

    # Splash screen
    @splash = true
    @splash_phase = 0
  end

  # ========== Init ==========

  def init
    scan_models
    scan_loras
    # Clean orphan mask files (older than 1 day)
    Dir.glob(File.join(@output_dir, ".mask_*.png")).each do |f|
      File.delete(f) if (Time.now - File.mtime(f)) > 86400
    rescue
      nil
    end
    update_param_keys
    _spinner, spinner_cmd = @spinner.init
    splash_cmd = Bubbletea.tick(0.4) { SplashTickMessage.new(phase: 1) }
    cmds = [spinner_cmd, splash_cmd]
    cmds << set_status_toast("Config created at #{CONFIG_PATH}") if @first_run_toast
    [self, Bubbletea.batch(*cmds)]
  end

  # ========== Update ==========

  def update(message)
    case message
    when Bubbletea::WindowSizeMessage
      @width = message.width; @height = message.height
      resize_components
      [self, nil]
    when Bubbles::Spinner::TickMessage
      @spinner, cmd = @spinner.update(message)
      [self, cmd]
    when Bubbles::Progress::FrameMessage
      @progress, cmd = @progress.update(message)
      [self, cmd]
    when GenerationDoneMessage
      @generating = false; @gen_pid = nil; @gen_start_time = nil
      @last_output_path = message.output_path
      @last_generation_time = message.elapsed
      @preview_cache = nil
      @error_message = nil
      output_msg = "output: #{File.basename(message.output_path)} \u2502 #{message.elapsed}s"
      output_msg += " \u2502 seed #{@last_seed}" if @last_seed
      [self, set_status_toast(output_msg)]
    when RevealTickMessage
      handle_reveal_tick(message)
    when GenerationErrorMessage
      @generating = false; @gen_pid = nil; @gen_start_time = nil
      @status_message = nil
      [self, set_error_toast(message.error)]
    when ReposFetchedMessage
      handle_repos_fetched(message)
    when ReposFetchErrorMessage
      @fetching = false
      [self, set_error_toast("Fetch failed: #{message.error}")]
    when FilesFetchedMessage
      handle_files_fetched(message)
    when FilesFetchErrorMessage
      @fetching = false
      [self, set_error_toast("Fetch failed: #{message.error}")]
    when ModelDownloadDoneMessage
      handle_download_done(message)
    when ModelDownloadErrorMessage
      @model_downloading = false; @download_dest = nil; @download_filename = ""
      [self, set_error_toast("Download failed: #{message.error}")]
    when LoraDownloadDoneMessage
      handle_lora_download_done(message)
    when LoraDownloadErrorMessage
      @lora_downloading = false; @lora_download_dest = nil; @lora_download_filename = ""
      [self, set_error_toast("Download failed: #{message.error}")]
    when LoraReposFetchedMessage
      handle_lora_repos_fetched(message)
    when LoraReposFetchErrorMessage
      @fetching = false
      [self, set_error_toast("Fetch failed: #{message.error}")]
    when LoraFilesFetchedMessage
      handle_lora_files_fetched(message)
    when LoraFilesFetchErrorMessage
      @fetching = false
      [self, set_error_toast("Fetch failed: #{message.error}")]
    when CompanionDownloadDoneMessage
      @companion_remaining -= 1
      # Start next companion download (sequential with progress)
      return start_next_companion_download(@companion_queue || [], @companion_hf_token)
    when CompanionDownloadErrorMessage
      @companion_remaining -= 1
      @companion_errors << "#{message.name}: #{message.error}"
      # Continue with next even if one failed
      return start_next_companion_download(@companion_queue || [], @companion_hf_token)
    when StarterPackItemDoneMessage
      @starter_pack_completed += 1
      return start_next_starter_pack_item
    when StarterPackItemErrorMessage
      @starter_pack_completed += 1
      @starter_pack_errors << message.item_name
      return start_next_starter_pack_item
    when PromptEnhanceMessage
      handle_prompt_enhance_result(message)
    when ClipboardPasteMessage
      if message.error
        @error_message = message.error
        [self, nil]
      else
        @init_image_path = message.path
        @controlnet_image_path = message.path if @controlnet_model_path
        [self, set_status_toast("Pasted image: #{File.basename(message.path)}")]
      end
    when ModelValidatedMessage
      handle_model_validated(message)
    when FilePickerPreviewMessage
      return [self, nil] unless message.generation == @file_picker_preview_gen
      if message.thumb
        @file_picker_thumb_cache[message.path] = message.thumb if message.path
        @file_picker_preview_ready = true
        [self, nil]
      else
        file_picker_load_thumb_async
      end
    when GalleryPreviewMessage
      return [self, nil] unless message.generation == @gallery_preview_gen
      if message.thumb
        @gallery_thumb_cache[message.path] = message.thumb if message.path
        @gallery_preview_ready = true
        [self, nil]
      else
        gallery_load_thumb_async
      end
    when SplashTickMessage
      handle_splash_tick(message)
    when StatusDismissMessage
      @status_message = nil if message.generation == @status_generation
      [self, nil]
    when ErrorDismissMessage
      @error_message = nil if message.generation == @error_generation
      [self, nil]
    when Bubbletea::KeyMessage
      return dismiss_splash if @splash
      handle_key(message)
    when Bubbletea::MouseMessage
      return dismiss_splash if @splash
      handle_mouse(message)
    else
      forward_to_focused(message)
    end
  end

  # ========== View ==========

  def view
    apply_theme_styles
    @chip_hit_map = []
    @kitty_overlay_pending = nil

    # Shrink dimensions for padding: 2 chars left/right, 1 line top/bottom
    saved_w = @width; saved_h = @height
    @width = @width - 4
    @height = @height - 2

    content = if @splash
      render_splash
    else
      case @overlay
      when :models
        title = @provider.provider_type == :api ? "#{@provider.display_name} Models" : "Models"
        render_overlay_panel(title, render_models_content, render_models_status)
      when :download then render_download_view
      when :lora
        family = current_model_family
        lora_title = family ? "LoRA Selection [#{family}]" : "LoRA Selection"
        render_overlay_panel(lora_title, render_lora_content, render_lora_status)
      when :lora_download then render_lora_download_view
      when :cn_download then render_overlay_panel("ControlNet Models", render_cn_download_content, render_cn_download_status)
      when :help then render_help_view
      when :preset   then render_overlay_panel("Presets", render_preset_content, render_preset_status)
      when :hf_token then render_overlay_panel("HuggingFace Token", render_hf_token_content, render_hf_token_status)
      when :gallery  then render_gallery_view
      when :fullscreen_image then render_fullscreen_image
      when :file_picker then render_file_picker_view
      when :mask_painter then render_mask_painter_view
      when :starter_pack then render_starter_pack_view
      when :theme then render_overlay_panel("Theme", render_theme_content, render_theme_status)
      when :provider then render_overlay_panel("Provider", render_provider_content, render_provider_status)
      when :api_key then render_overlay_panel("API Key", render_api_key_content, render_api_key_status)
      else render_main_view
      end
    end

    @width = saved_w; @height = saved_h

    # Fill entire terminal with theme surface background, with inner padding
    output = Lipgloss::Style.new.background(Theme.SURFACE).width(@width).height(@height).padding(1, 2).render(content)

    # Every inner style emits \e[0m (SGR reset), which clears background back to
    # the terminal default. Re-apply the surface background after every reset so
    # the theme color persists across all styled text.
    bg_seq = surface_bg_escape
    result = output.gsub("\e[0m", "\e[0m#{bg_seq}")

    # Kitty overlay: append after all lipgloss processing is done
    # so the APC sequences don't interfere with width calculations
    if @kitty_graphics && @kitty_overlay_pending
      result << build_kitty_overlay(@kitty_overlay_pending)
      @kitty_overlay_pending = nil
    end

    result
  end
end
