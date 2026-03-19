# frozen_string_literal: true

module Chewy::Presets
  private

  def all_presets
    builtin = BUILTIN_PRESETS.map { |n, d| { name: n, data: d, builtin: true } }
    user = @user_presets.map { |n, d| { name: n, data: d, builtin: false } }
    builtin + user
  end

  def load_preset(preset)
    d = preset[:data]
    @params[:steps] = d["steps"] if d["steps"]
    @params[:cfg_scale] = d["cfg_scale"].to_f if d["cfg_scale"]
    @params[:width] = d["width"] if d["width"]
    @params[:height] = d["height"] if d["height"]
    @params[:seed] = d["seed"] if d["seed"]
    @params[:batch] = d["batch"] if d["batch"]
    if d["sampler"]
      @sampler = d["sampler"]
      @sampler_index = SAMPLER_OPTIONS.index(@sampler) || 1
    end
    if d["scheduler"]
      @scheduler = d["scheduler"]
      @scheduler_index = SCHEDULER_OPTIONS.index(@scheduler) || 0
    end
    @params[:strength] = d["strength"].to_f if d["strength"]

    # Model selection: exact path (user presets) or type match (builtins)
    if d["model"] && File.exist?(d["model"])
      @selected_model_path = d["model"]
      @preview_cache = nil
    elsif d["model_type"] && @provider.provider_type == :local
      select_model_by_type(d["model_type"])
    end
  end

  def select_model_by_type(type)
    return unless File.directory?(@models_dir)
    pattern = case type
    when "flux" then /flux/i
    when "sdxl" then /sdxl|sd_xl/i
    when "sd3" then /sd3/i
    when "sd" then /sd[_\-]?1|v1[_\-]|stable.diffusion.*1/i
    end
    return unless pattern

    # Prefer pinned models, then recent, then any match
    candidates = Dir.glob(File.join(@models_dir, "**", "*.{gguf,safetensors,ckpt}"))
    match = (@pinned_models || []).find { |p| File.basename(p) =~ pattern && File.exist?(p) }
    match ||= (@recent_models || []).find { |p| File.basename(p) =~ pattern && File.exist?(p) }
    match ||= candidates.find { |p| File.basename(p) =~ pattern }

    if match
      @selected_model_path = match
      @preview_cache = nil
    end
  end

  def save_user_preset(name)
    data = {
      "steps" => @params[:steps], "cfg_scale" => @params[:cfg_scale],
      "width" => @params[:width], "height" => @params[:height],
      "seed" => @params[:seed], "sampler" => @sampler, "scheduler" => @scheduler,
      "batch" => @params[:batch],
    }
    data["model"] = @selected_model_path if @selected_model_path
    data["strength"] = @params[:strength] if @init_image_path
    @user_presets[name] = data
    save_presets
  end

  def delete_preset_at(idx)
    all = all_presets
    p = all[idx]
    return if !p || p[:builtin]
    @user_presets.delete(p[:name])
    save_presets
    @preset_index = [0, @preset_index - 1].max
  end
end
