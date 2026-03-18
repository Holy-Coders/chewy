# frozen_string_literal: true

# ---------- Local sd.cpp Provider ----------

class LocalSdCppProvider < Provider::Base
  def initialize(sd_bin:, models_dir:, lora_dir:)
    @sd_bin = sd_bin; @models_dir = models_dir; @lora_dir = lora_dir
  end

  def id; "local_sd_cpp"; end
  def display_name; "Local (sd.cpp)"; end
  def provider_type; :local; end

  def capabilities
    Provider::Capabilities.new(
      negative_prompt: true, seed: true, batch: true, img2img: true,
      live_preview: true, cancel: true, model_listing: true, lora: true,
      cfg_scale: true, sampler: true, scheduler: true, threads: true,
      strength: true, width_height: true, controlnet: true
    )
  end

  def generate(request, cancelled: -> { false }, &on_event)
    preview_path = File.join(request.output_dir, ".preview_#{Process.pid}.png")
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    output_path = File.join(request.output_dir, "#{timestamp}.png")

    on_event&.call(:preview_path, preview_path)

    args = build_command(request, output_path, preview_path)

    start_time = Time.now
    pty_r, _pty_w, pid = PTY.spawn(*args)
    on_event&.call(:pid, pid)

    all_output = +""; parsed_seed = nil; sampling_started = false
    buf = +""; status = nil; batch_seeds = []

    loop do
      ready = IO.select([pty_r], nil, nil, 0.25)
      if ready
        begin
          chunk = pty_r.readpartial(4096)
          buf << chunk; all_output << chunk
          parse_output(buf, sampling_started, parsed_seed, on_event) do |new_buf, ss, ps|
            if ps && ps != parsed_seed
              batch_seeds << ps
              on_event&.call(:batch_progress, batch_seeds.length)
            end
            buf = new_buf; sampling_started = ss; parsed_seed = ps
          end
        rescue Errno::EIO, EOFError
          break
        end
      end
      begin
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        if status
          loop do
            chunk = pty_r.readpartial(4096)
            all_output << chunk; buf << chunk
            parse_output(buf, sampling_started, parsed_seed, on_event) do |new_buf, ss, ps|
              if ps && ps != parsed_seed
                batch_seeds << ps
                on_event&.call(:batch_progress, batch_seeds.length)
              end
              buf = new_buf; sampling_started = ss; parsed_seed = ps
            end
          rescue Errno::EIO, EOFError
            break
          end
          break
        end
      rescue Errno::ECHILD
        break
      end
    end

    _, status = Process.wait2(pid) rescue nil unless status
    pty_r.close rescue nil
    on_event&.call(:pid, nil)
    elapsed = (Time.now - start_time).round(1)

    File.delete(preview_path) if File.exist?(preview_path)
    on_event&.call(:preview_path, nil)

    if cancelled.call || status&.signaled?
      cleanup_outputs(output_path, request.batch)
      return Provider::GenerationResult.new(error: "Cancelled")
    end

    if status&.success? || status.nil?
      generated = collect_outputs(output_path, request, batch_seeds, parsed_seed)
      if generated.any?
        Provider::GenerationResult.new(
          paths: generated.map(&:first), seeds: generated.map(&:last), elapsed: elapsed
        )
      else
        Provider::GenerationResult.new(error: diagnose_error(all_output, status, request.model))
      end
    else
      Provider::GenerationResult.new(error: diagnose_error(all_output, status, request.model))
    end
  rescue Errno::ENOENT
    on_event&.call(:pid, nil)
    Provider::GenerationResult.new(error: "Binary '#{@sd_bin}' not found. Set SD_BIN env var.")
  rescue => e
    on_event&.call(:pid, nil)
    Provider::GenerationResult.new(error: e.message)
  end

  def cancel(pid)
    Process.kill("TERM", pid) rescue nil
  end

  private

  def build_command(request, output_path, preview_path)
    args = if request.is_flux
      [@sd_bin, "--diffusion-model", request.model,
       "--clip_l", request.flux_clip_l, "--t5xxl", request.flux_t5xxl, "--vae", request.flux_vae,
       "-p", request.prompt,
       "--steps", request.steps.to_s, "--cfg-scale", request.cfg_scale.to_s,
       "--guidance", "3.5",
       "-W", request.width.to_s, "-H", request.height.to_s,
       "--seed", request.seed.to_s, "--sampling-method", request.sampler,
       "--scheduler", request.scheduler,
       "-t", request.threads.to_s, "--fa", "--vae-tiling", "--clip-on-cpu",
       "--cache-mode", "spectrum",
       "-b", request.batch.to_s,
       "-o", output_path]
    else
      [@sd_bin, "-m", request.model, "-p", request.prompt,
       "--steps", request.steps.to_s, "--cfg-scale", request.cfg_scale.to_s,
       "-W", request.width.to_s, "-H", request.height.to_s,
       "--seed", request.seed.to_s, "--sampling-method", request.sampler,
       "--scheduler", request.scheduler,
       "-t", request.threads.to_s, "--fa", "--vae-tiling", "--clip-on-cpu",
       "--cache-mode", "spectrum",
       "-b", request.batch.to_s,
       "-o", output_path]
    end
    args += ["--preview", "proj", "--preview-path", preview_path, "--preview-interval", "1"]
    args += ["--negative-prompt", request.negative_prompt] unless request.negative_prompt.empty?
    args += ["--lora-model-dir", @lora_dir] if request.loras&.any? && !request.is_flux
    if request.init_image
      args += ["--init-img", request.init_image, "--strength", request.strength.to_s]
    end
    if request.controlnet_model && request.controlnet_image
      args += ["--control-net", request.controlnet_model, "--control-image", request.controlnet_image]
      args += ["--control-strength", (request.controlnet_strength || 0.9).to_s]
      args << "--control-canny" if request.controlnet_canny
    end
    args
  end

  def parse_output(buf, sampling_started, parsed_seed, on_event)
    clean = buf.gsub(/\e\[[0-9;]*[A-Za-z]/, "")
    segments = clean.split(/[\r\n]+/)
    new_buf = clean.end_with?("\r", "\n") ? +"" : (segments.pop || +"")
    segments.each do |seg|
      stripped = seg.strip
      next if stripped.empty?
      if seg =~ /\[INFO\s*\]\s*\S+\s*-\s*(.+)/
        info = $1.strip
        if info =~ /loading model/i
          on_event&.call(:status, "Loading model...")
        elsif info =~ /load .+ using (\w+)/i
          on_event&.call(:status, "Loading (#{$1})...")
        elsif info =~ /Version:\s*(.+)/
          on_event&.call(:status, "Model: #{$1.strip}")
        elsif info =~ /total params memory size\s*=\s*([\d.]+\s*\w+)/
          on_event&.call(:status, "Model loaded (#{$1})")
        elsif info =~ /sampling using (.+) method/i
          on_event&.call(:status, "Sampler: #{$1}")
        elsif info =~ /generating image.*seed\s+(\d+)/i
          parsed_seed = $1.to_i
          sampling_started = true
          on_event&.call(:sampling_start, nil)
          on_event&.call(:status, "Sampling (seed #{$1})...")
        elsif info =~ /sampling completed/i
          on_event&.call(:status, "Decoding latents...")
        elsif info =~ /save result/i
          on_event&.call(:status, "Saving image...")
        end
      end
      if !sampling_started && seg =~ /seed\s+(\d+)/i
        parsed_seed = $1.to_i
        sampling_started = true
        on_event&.call(:sampling_start, nil)
      end
      if sampling_started && seg =~ /(\d+)\s*\/\s*(\d+)\s*-\s*([\d.]+)\s*(s\/it|it\/s)/
        step = $1.to_i; total = $2.to_i
        speed_val = $3.to_f
        sps = $4 == "s/it" ? speed_val : (speed_val > 0 ? 1.0 / speed_val : 0)
        on_event&.call(:progress, { step: step, total: total, secs_per_step: sps })
      end
    end
    yield new_buf, sampling_started, parsed_seed
  end

  def collect_outputs(output_path, request, batch_seeds, parsed_seed)
    generated = []
    if request.batch > 1
      base = output_path.sub(/\.png$/, "")
      request.batch.times do |i|
        f = "#{base}_#{i}.png"
        next unless File.exist?(f) && File.size(f) > 0
        ts = Time.now.strftime("%Y%m%d_%H%M%S_%L") + "_#{i}"
        final = File.join(request.output_dir, "#{ts}.png")
        File.rename(f, final)
        generated << [final, batch_seeds[i] || (request.seed == -1 ? nil : request.seed + i)]
      end
    else
      if File.exist?(output_path) && File.size(output_path) > 0
        generated << [output_path, parsed_seed || request.seed]
      end
    end
    generated
  end

  def cleanup_outputs(output_path, batch_count)
    if batch_count > 1
      batch_count.times { |i| File.delete("#{output_path.sub(/\.png$/, "")}_#{i}.png") rescue nil }
    else
      File.delete(output_path) rescue nil
    end
  end

  def diagnose_error(all_output, status, model)
    exit_code = status&.exitstatus || "unknown"
    last_line = all_output.lines.last&.strip || "unknown"
    if all_output.include?("get sd version from file failed") || all_output.include?("new_sd_ctx_t failed")
      name = File.basename(model)
      "\"#{name}\" is not a supported diffusion model — try a different model"
    elsif all_output.include?("out of memory") || all_output.include?("GGML_ASSERT")
      "Not enough memory for this model — try a smaller/quantized version"
    else
      "Failed (exit #{exit_code}): #{last_line}"
    end
  end
end
