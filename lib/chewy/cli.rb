# frozen_string_literal: true

# ---------- Logo ----------

CHEWY_LOGO = <<~'ART'
              ▄▄▄▄██▄▄▄▄
         ▄████████████████▄▄
        ▄███████▄  ████  ▄█████▄
       ▄██▀   ▀▀██  ██ ▄██▀▀▀████
      ███████▄   ██ █▀ █▀  ▄██████
     ▄██▀▀   ▀▀▄  ▀      ▄█▀▀ ▀▀███
    ▄██████▀                 ▄█████▄
    ███▀ ▄                      ▀███
    ████▀                      ▀▀███
    ██▀    ▄▄███▄▄▄   ▄▄███▄▄▄    ██
   ██▀   ▄█████████▀  █████████▄   █▄
   ██    ▀▀  ████▀ ▄ ▄▄▀████▀  ▀   ██
  ██ ▄▄       ▀▀ ▄██████          ▄▄█▄
  ████           ▀▀▀▀▀▀▀▄▄        ▀███
  ████ █  ▄              ▀▀█▄   █▄ ███
  █▀███  █▀   ▄▄█▀▀▀██████       █▄██▀
    ███ ██        ▄▄▄▄▄          ████
    ██ ▄█▀          ▀         █▄ ████
   ███▄███ █               ▄  ██▄█▀▀▀█
  ████▀ ██▄█▄  ▄          ██  ████
         ▀███▄ █▄     █ ▄██▀ ███▀
           ▀██ ███▄  █████▀ ▀▀
             █▄█▀▀██▄███▀
              ▀     ▀▀▀▀
ART

def cli_fg(hex)
  hex = hex.sub("#", "")
  "\e[38;2;#{hex[0,2].to_i(16)};#{hex[2,2].to_i(16)};#{hex[4,2].to_i(16)}m"
end

def cli_bold_fg(hex) = "\e[1m#{cli_fg(hex)}"

def cli_load_theme
  return if @cli_theme_loaded
  @cli_theme_loaded = true
  config = File.exist?(CONFIG_PATH) ? (YAML.safe_load(File.read(CONFIG_PATH)) || {}) : {}
  Theme.set(config["theme"] || "midnight")
rescue
  nil
end

def print_logo
  cli_load_theme
  c = cli_bold_fg(Theme.PRIMARY)
  CHEWY_LOGO.each_line do |line|
    puts "#{c}#{line}\e[0m"
  end
end

# ---------- Update Check ----------

def check_for_updates
  uri = URI.parse("https://api.github.com/repos/#{CHEWY_REPO}/releases/latest")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 3
  http.read_timeout = 3
  req = Net::HTTP::Get.new(uri)
  req["Accept"] = "application/vnd.github+json"
  resp = http.request(req)
  return nil unless resp.is_a?(Net::HTTPSuccess)

  data = JSON.parse(resp.body)
  latest = data["tag_name"]&.sub(/^v/, "")
  return nil unless latest

  current_parts = CHEWY_VERSION.split(".").map(&:to_i)
  latest_parts = latest.split(".").map(&:to_i)
  (latest_parts <=> current_parts) > 0 ? latest : nil
rescue
  nil
end

# ---------- CLI Helpers ----------

def cli_output_dir
  config = File.exist?(CONFIG_PATH) ? (YAML.safe_load(File.read(CONFIG_PATH)) || {}) : {}
  File.expand_path(ENV["CHEWY_OUTPUT_DIR"] || config["output_dir"] || "~/.config/chewy/outputs")
end

def cli_list_images
  cli_load_theme
  dir = cli_output_dir
  unless File.directory?(dir)
    puts "No output directory found at #{dir}"
    exit 0
  end

  pngs = Dir.glob(File.join(dir, "*.png")).sort.reverse
  video_dirs = Dir.glob(File.join(dir, "*_frames")).select { |d| File.directory?(d) }.sort.reverse

  if pngs.empty? && video_dirs.empty?
    puts "No images or videos found in #{dir}"
    exit 0
  end

  primary = cli_bold_fg(Theme.PRIMARY)
  accent = cli_fg(Theme.ACCENT)
  dim = cli_fg(Theme.TEXT_DIM)
  video_style = cli_bold_fg(Theme.ACCENT)
  total = pngs.length + video_dirs.length
  puts "#{primary}Images in #{dir}\e[0m (#{total} total)\n\n"

  idx_counter = 0

  # List videos first
  video_dirs.each do |vdir|
    idx_counter += 1
    json = File.join(vdir, "video.json")
    meta = File.exist?(json) ? (JSON.parse(File.read(json)) rescue {}) : {}
    prompt = (meta["prompt"] || "")[0, 60]
    model = meta["model"] ? File.basename(meta["model"]) : nil
    frame_count = meta["frame_count"] || Dir.glob(File.join(vdir, "*.png")).length
    fps = meta["fps"] || 24
    mp4 = Dir.glob(File.join(vdir, "*.mp4")).first

    idx = "#{primary}#{idx_counter}.\e[0m"
    name = "#{video_style}[VIDEO]\e[0m \e[1m#{File.basename(vdir)}\e[0m"
    details = ["#{frame_count} frames", "#{fps} fps", model, mp4 ? "mp4" : nil].compact.join(" | ")
    puts "  #{idx} #{name}"
    puts "     #{prompt}" unless prompt.empty?
    puts "     #{dim}#{details}\e[0m" unless details.empty?
    puts ""
  end

  pngs.each do |png|
    idx_counter += 1
    json = png.sub(/\.png$/, ".json")
    meta = File.exist?(json) ? (JSON.parse(File.read(json)) rescue {}) : {}
    prompt = (meta["prompt"] || "")[0, 60]
    model = meta["model"] ? File.basename(meta["model"]) : nil
    seed = meta["seed"]

    idx = "#{primary}#{idx_counter}.\e[0m"
    name = "\e[1m#{File.basename(png)}\e[0m"
    details = [model, seed ? "seed:#{seed}" : nil].compact.join(" | ")
    puts "  #{idx} #{name}"
    puts "     #{prompt}" unless prompt.empty?
    puts "     #{dim}#{details}\e[0m" unless details.empty?
    puts ""
  end
end

def cli_delete_image(target)
  cli_load_theme
  dir = cli_output_dir
  # Resolve path — bare filename is joined with output dir
  path = File.expand_path(target.include?("/") ? target : File.join(dir, target))

  # Validate path is within the output directory to prevent path traversal
  output_real = File.realpath(dir) rescue File.expand_path(dir)
  path_real = File.realpath(path) rescue path
  unless path_real.start_with?(output_real + "/") || path_real == output_real
    puts "#{cli_fg(Theme.ERROR)}Path must be within output directory:\e[0m #{dir}"
    exit 1
  end

  # Check if target is a video frames directory
  is_video_dir = File.directory?(path) && path.end_with?("_frames")

  unless File.exist?(path) || is_video_dir
    puts "#{cli_fg(Theme.ERROR)}File not found:\e[0m #{target}"
    exit 1
  end

  label = is_video_dir ? "[VIDEO] #{File.basename(path)}" : File.basename(path)
  print "Delete #{label}? [y/N] "
  answer = $stdin.gets&.strip&.downcase
  unless answer == "y"
    puts "Cancelled."
    exit 0
  end

  if is_video_dir
    FileUtils.rm_rf(path)
  else
    json = path.sub(/\.png$/, ".json")
    File.delete(path) if File.exist?(path)
    File.delete(json) if File.exist?(json)
  end
  puts "#{cli_fg(Theme.SUCCESS)}Deleted\e[0m #{label}"
end
