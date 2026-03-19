# frozen_string_literal: true

class Chewy
  module Config
    private

    def load_config
      return {} unless File.exist?(CONFIG_PATH)
      YAML.safe_load(File.read(CONFIG_PATH)) || {}
    rescue
      {}
    end

    def save_config
      FileUtils.mkdir_p(CONFIG_DIR)
      data = {
        "model_dir" => @models_dir || File.expand_path("~/.config/chewy/models"),
        "output_dir" => @output_dir || "~/.config/chewy/outputs",
        "sd_bin" => @sd_bin || "sd",
        "lora_dir" => @lora_dir || File.expand_path("~/.config/chewy/loras"),
        "default_steps" => @params&.dig(:steps) || 20,
        "default_cfg" => @params&.dig(:cfg_scale) || 7.0,
        "default_width" => @params&.dig(:width) || 512,
        "default_height" => @params&.dig(:height) || 512,
        "default_sampler" => @sampler || "euler_a",
        "default_scheduler" => @scheduler || "discrete",
        "default_threads" => @params&.dig(:threads) || Etc.nprocessors,
        "pinned_models" => @pinned_models || [],
        "recent_models" => @recent_models || [],
        "last_model" => @selected_model_path,
        "incompatible_models" => @incompatible_models || [],
        "model_types" => @model_types || {},
        "theme" => Theme.current_name,
        "active_provider" => @provider&.id || "local_sd_cpp",
        "remote_model" => @remote_model_id,
        "default_video_frames" => @params&.dig(:video_frames) || 33,
        "default_fps" => @params&.dig(:fps) || 24,
      }
      @config = data
      File.write(CONFIG_PATH, YAML.dump(data))
      File.chmod(0600, CONFIG_PATH) rescue nil
    rescue
      nil
    end

    def load_presets
      return {} unless File.exist?(PRESETS_PATH)
      YAML.safe_load(File.read(PRESETS_PATH)) || {}
    rescue
      {}
    end

    def save_presets
      FileUtils.mkdir_p(CONFIG_DIR)
      File.write(PRESETS_PATH, YAML.dump(@user_presets))
      File.chmod(0600, PRESETS_PATH) rescue nil
    rescue
      nil
    end

    def build_providers
      providers = [
        LocalSdCppProvider.new(sd_bin: @sd_bin, models_dir: @models_dir, lora_dir: @lora_dir),
        OpenAIImagesProvider.new,
        GeminiProvider.new,
        HuggingFaceInferenceProvider.new,
        A1111Provider.new(@config["a1111"] || {}),
      ]
      # Add user-configured OpenAI-compatible endpoint if present
      if (compat_cfg = @config["openai_compatible"])
        providers << OpenAICompatibleProvider.new(compat_cfg)
      end
      providers
    end

    def update_param_keys
      model_id = @provider.provider_type == :api ? @remote_model_id : nil
      caps = model_id ? @provider.capabilities_for_model(model_id) : @provider.capabilities
      keys = []
      keys << :steps if caps.sampler || caps.cfg_scale
      keys << :cfg_scale if caps.cfg_scale
      keys << :width << :height if caps.width_height
      keys << :seed if caps.seed
      keys << :sampler if caps.sampler
      keys << :scheduler if caps.scheduler
      keys << :batch if caps.batch
      keys << :strength if caps.strength
      # Guidance is FLUX-specific (separate from cfg_scale)
      if @provider.provider_type == :local && @selected_model_path && flux_model?(@selected_model_path)
        keys << :guidance
      end
      # Video params for Wan models
      if @provider.provider_type == :local && @selected_model_path && wan_model?(@selected_model_path)
        keys << :video_frames
        keys << :fps
      end
      keys << :threads if caps.threads
      if caps.controlnet
        keys << :cn_model
        keys << :cn_image
        keys << :cn_strength
        keys << :cn_canny
      end
      keys << :mask_image if caps.inpainting
      @param_display_keys = keys
      @param_index = [[@param_index, keys.length - 1].min, 0].max
    end
  end
end
