# frozen_string_literal: true

class Chewy
  module Upscale
    private

    def esrgan_path
      File.join(@models_dir, ESRGAN_MODEL[:filename])
    end

    def esrgan_present?
      File.exist?(esrgan_path)
    end

    def download_esrgan
      FileUtils.mkdir_p(@models_dir)
      dest = esrgan_path
      part = "#{dest}.part"
      url = ESRGAN_MODEL[:url]
      @companion_downloading = true
      @companion_current_file = ESRGAN_MODEL[:filename]
      @companion_dest = part
      @companion_remaining = 1
      @companion_errors = []
      cmd = Proc.new do
        _out, err, st = Open3.capture3("curl", "-fL", "-o", part, "-sS",
          "-C", "-", "--retry", "3", "--retry-delay", "2", "--retry-all-errors", url)
        if st.success?
          File.rename(part, dest)
          CompanionDownloadDoneMessage.new(name: "esrgan")
        else
          File.delete(part) rescue nil
          CompanionDownloadErrorMessage.new(name: "esrgan", error: "curl failed: #{err.strip}")
        end
      rescue => e
        File.delete(part) rescue nil
        CompanionDownloadErrorMessage.new(name: "esrgan", error: e.message)
      end
      [self, cmd]
    end

    def start_upscale(src_path)
      return [self, set_error_toast("Source image not found")] unless src_path && File.exist?(src_path)
      return download_esrgan unless esrgan_present?

      FileUtils.mkdir_p(@output_dir)
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
      out_path = File.join(@output_dir, "#{timestamp}_upscaled.png")

      sd_bin = @sd_bin
      model_path = esrgan_path
      @gen_status = "Upscaling #{File.basename(src_path)}..."

      cmd = Proc.new do
        start = Time.now
        _out, err, st = Open3.capture3(sd_bin,
          "-M", "upscale",
          "--upscale-model", model_path,
          "-i", src_path,
          "-o", out_path)
        elapsed = (Time.now - start).round(1)
        if st.success? && File.exist?(out_path)
          # Write a minimal sidecar so gallery can show provenance
          sidecar = {
            "source_image" => src_path,
            "upscaler" => "Real-ESRGAN x#{ESRGAN_MODEL[:scale]}",
            "timestamp" => Time.now.iso8601,
            "generation_time_seconds" => elapsed,
          }
          File.write(out_path.sub(/\.png$/, ".json"), JSON.pretty_generate(sidecar))
          UpscaleDoneMessage.new(output_path: out_path, elapsed: elapsed)
        else
          UpscaleErrorMessage.new(error: (err.lines.last&.strip || "upscale failed (exit #{st.exitstatus})"))
        end
      rescue => e
        UpscaleErrorMessage.new(error: e.message)
      end
      [self, cmd]
    end

    def handle_upscale_done(message)
      @gen_status = nil
      build_gallery if @overlay == :gallery
      [self, set_status_toast("Upscaled in #{message.elapsed}s — #{File.basename(message.output_path)}")]
    end

    def handle_upscale_error(message)
      @gen_status = nil
      [self, set_error_toast("Upscale failed: #{message.error}")]
    end
  end
end
