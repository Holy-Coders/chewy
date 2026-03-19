# frozen_string_literal: true

module Chewy::Overlays
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
end
