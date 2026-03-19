# frozen_string_literal: true

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

def cli_output_dir
  config = File.exist?(CONFIG_PATH) ? (YAML.safe_load(File.read(CONFIG_PATH)) || {}) : {}
  ENV["CHEWY_OUTPUT_DIR"] || config["output_dir"] || "outputs"
end

def cli_list_images
  cli_load_theme
  dir = cli_output_dir
  unless File.directory?(dir)
    puts "No output directory found at #{dir}"
    exit 0
  end

  pngs = Dir.glob(File.join(dir, "*.png")).sort.reverse
  if pngs.empty?
    puts "No images found in #{dir}"
    exit 0
  end

  primary = cli_bold_fg(Theme.PRIMARY)
  accent = cli_fg(Theme.ACCENT)
  dim = cli_fg(Theme.TEXT_DIM)
  puts "#{primary}Images in #{dir}\e[0m (#{pngs.length} total)\n\n"
  pngs.each_with_index do |png, i|
    json = png.sub(/\.png$/, ".json")
    meta = File.exist?(json) ? (JSON.parse(File.read(json)) rescue {}) : {}
    prompt = (meta["prompt"] || "")[0, 60]
    model = meta["model"] ? File.basename(meta["model"]) : nil
    seed = meta["seed"]

    idx = "#{primary}#{i + 1}.\e[0m"
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
  path = File.exist?(target) ? target : File.join(dir, target)

  unless File.exist?(path)
    puts "#{cli_fg(Theme.ERROR)}File not found:\e[0m #{target}"
    exit 1
  end

  json = path.sub(/\.png$/, ".json")
  print "Delete #{File.basename(path)}? [y/N] "
  answer = $stdin.gets&.strip&.downcase
  unless answer == "y"
    puts "Cancelled."
    exit 0
  end

  File.delete(path) if File.exist?(path)
  File.delete(json) if File.exist?(json)
  puts "#{cli_fg(Theme.SUCCESS)}Deleted\e[0m #{File.basename(path)}"
end

def run_cli
  case ARGV[0]
  when "list", "ls"
    cli_list_images
    exit 0
  when "delete", "rm"
    if ARGV[1].nil?
      puts "Usage: chewy delete <filename>"
      puts "       chewy list    # to see available images"
      exit 1
    end
    cli_delete_image(ARGV[1])
    exit 0
  when "--help", "-h", "help"
    print_logo
    puts "#{cli_bold_fg(Theme.PRIMARY)}chewy v#{CHEWY_VERSION}\e[0m — local AI image generation TUI\n\n"
    puts "Usage: chewy [command]\n\n"
    puts "Commands:"
    puts "  (none)          Launch the TUI"
    puts "  list, ls        List all generated images"
    puts "  delete, rm FILE Delete a generated image"
    puts "  help, --help    Show this help\n\n"
    exit 0
  end

  if (new_version = check_for_updates)
    print_logo
    puts "#{cli_bold_fg(Theme.PRIMARY)}chewy v#{CHEWY_VERSION}\e[0m -> #{cli_bold_fg(Theme.SUCCESS)}v#{new_version}\e[0m available!"
    puts ""
    puts "  brew upgrade Holy-Coders/chewy/chewy"
    puts ""
    print "Continue with current version? [Y/n] "
    answer = $stdin.gets&.strip&.downcase
    exit 0 if answer == "n"
    puts ""
  end

  Bubbletea.run(Chewy.new, alt_screen: true, mouse_cell_motion: true)
end
