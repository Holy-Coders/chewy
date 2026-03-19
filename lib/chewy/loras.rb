# frozen_string_literal: true

class Chewy
  module Loras
    private

    def scan_loras
      return unless File.directory?(@lora_dir)
      pattern = File.join(@lora_dir, "**", "*.safetensors")
      all_loras = Dir.glob(pattern).map do |f|
        name = File.basename(f, ".safetensors")
        family = detect_lora_family(name, f)
        { name: name, path: f, family: family }
      end
      @all_loras = all_loras
      filter_loras
    end

    # Filter available LoRAs by current model family.
    # Incompatible LoRAs are shown separately so user knows they exist but can't select them.
    def filter_loras
      family = current_model_family
      if family
        @available_loras = (@all_loras || []).select { |l| l[:family].nil? || l[:family] == family }
        @incompatible_loras = (@all_loras || []).select { |l| l[:family] && l[:family] != family }
      else
        @available_loras = @all_loras || []
        @incompatible_loras = []
      end
      # Remove any selected LoRAs that are no longer compatible
      @selected_loras.reject! { |sl| !@available_loras.any? { |al| al[:path] == sl[:path] } } if @selected_loras
      @lora_index = [[@lora_index, @available_loras.length - 1].min, 0].max
    end

    def detect_lora_family(name, path)
      n = (name || File.basename(path, ".safetensors")).downcase
      dir = File.dirname(path).downcase
      combined = "#{dir}/#{n}"
      if combined.include?("flux")
        "FLUX"
      elsif combined.include?("sdxl") || combined.include?("sd_xl") || combined.include?("xl")
        "SDXL"
      elsif combined.include?("sd15") || combined.include?("sd1.") || combined.include?("sd_1") || combined.include?("v1-") || combined.include?("v1_")
        "SD 1.x"
      elsif combined.include?("sd2") || combined.include?("v2-")
        "SD 2.x"
      elsif combined.include?("sd3")
        "SD3"
      end
    end

    # Keep old name as alias for backward compat in generation validation
    alias detect_lora_type detect_lora_family

    def lora_compatible?(name, path, model_type)
      lora_family = detect_lora_family(name, path)
      return true unless lora_family # unknown LoRA family — allow it
      model_fam = model_family_for(model_type)
      return true unless model_fam
      lora_family == model_fam
    end

    # Get metadata for a recommended LoRA by filename
    def recommended_lora_metadata(filename)
      RECOMMENDED_LORAS.find { |l| l[:file] == filename }
    end

    # Get metadata for a local LoRA (check recommended list first, then infer)
    def lora_metadata(lora)
      basename = File.basename(lora[:path])
      rec = RECOMMENDED_LORAS.find { |l| l[:file] == basename }
      if rec
        {
          model_family: rec[:model_family],
          lora_type: rec[:lora_type],
          desc: rec[:desc],
          use_for: rec[:use_for],
          avoid: rec[:avoid],
          recommended_weight: rec[:recommended_weight],
          tags: rec[:tags],
          example_prompt: rec[:example_prompt],
        }
      else
        family = detect_lora_family(lora[:name], lora[:path])
        {
          model_family: family,
          lora_type: nil,
          desc: nil,
          use_for: nil,
          avoid: nil,
          recommended_weight: nil,
          tags: nil,
          example_prompt: nil,
        }
      end
    end

    def toggle_lora_selection(idx)
      return if idx >= @available_loras.length
      lora = @available_loras[idx]
      existing = @selected_loras.find_index { |l| l[:path] == lora[:path] }
      if existing
        @selected_loras.delete_at(existing)
      else
        meta = lora_metadata(lora)
        default_weight = meta.dig(:recommended_weight, :default) || 1.0
        @selected_loras << { name: lora[:name], path: lora[:path], weight: default_weight }
      end
    end

    def adjust_lora_weight(idx, delta)
      return if idx >= @available_loras.length
      lora = @available_loras[idx]
      sel = @selected_loras.find { |l| l[:path] == lora[:path] }
      sel[:weight] = (sel[:weight] + delta).round(1).clamp(0.0, 2.0) if sel
    end
  end
end
