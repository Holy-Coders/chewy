# frozen_string_literal: true

# ---------- Provider Interface ----------

module Provider
  Capabilities = Struct.new(
    :negative_prompt, :seed, :batch, :img2img, :live_preview,
    :cancel, :model_listing, :lora, :cfg_scale, :sampler,
    :scheduler, :threads, :strength, :width_height, :controlnet,
    keyword_init: true
  ) do
    def initialize(**kwargs)
      defaults = { negative_prompt: false, seed: false, batch: false, img2img: false,
                   live_preview: false, cancel: false, model_listing: false, lora: false,
                   cfg_scale: false, sampler: false, scheduler: false, threads: false,
                   strength: false, width_height: true, controlnet: false }
      super(**defaults.merge(kwargs))
    end
  end

  GenerationRequest = Struct.new(
    :prompt, :negative_prompt, :model, :steps, :cfg_scale,
    :width, :height, :seed, :sampler, :scheduler, :batch,
    :init_image, :strength, :threads, :loras, :output_dir,
    :is_flux, :flux_clip_l, :flux_t5xxl, :flux_vae,
    :controlnet_model, :controlnet_image, :controlnet_strength, :controlnet_canny,
    keyword_init: true
  )

  GenerationResult = Struct.new(:paths, :seeds, :elapsed, :error, keyword_init: true)

  # Where provider API keys are stored (not in config YAML)
  KEYS_DIR = File.join(CONFIG_DIR, "keys")

  class Base
    def id; raise NotImplementedError; end
    def display_name; raise NotImplementedError; end
    def provider_type; :local; end
    def capabilities; raise NotImplementedError; end
    def capabilities_for_model(model_id); capabilities; end
    def list_models; []; end
    def generate(request, cancelled: -> { false }, &on_event); raise NotImplementedError; end
    def cancel(handle); end
    def needs_api_key?; false; end
    def api_key_env_var; nil; end
    def api_key_setup_url; nil; end
    def api_key_set?; !needs_api_key?; end

    def resolve_api_key
      return nil unless needs_api_key?
      # Env var takes priority, then stored key file
      ENV[api_key_env_var] || load_stored_key
    end

    def store_api_key(key)
      FileUtils.mkdir_p(Provider::KEYS_DIR)
      path = File.join(Provider::KEYS_DIR, "#{id}.key")
      File.write(path, key)
      File.chmod(0600, path)
    rescue => e
      nil
    end

    private

    def load_stored_key
      path = File.join(Provider::KEYS_DIR, "#{id}.key")
      return nil unless File.exist?(path)
      key = File.read(path).strip
      key.empty? ? nil : key
    rescue
      nil
    end
  end
end
