# frozen_string_literal: true

BUILTIN_THEMES = {
  "midnight" => {
    "primary" => "#874BFD", "secondary" => "#7B2FFF", "accent" => "#FF75B5",
    "success" => "#50FA7B", "warning" => "#F1FA8C", "error" => "#FF5555",
    "text" => "#E2E2E8", "text_dim" => "#8888A0", "text_muted" => "#5C5C78",
    "surface" => "#1E1E2E", "border_dim" => "#3A3A52", "border_focus" => "#874BFD",
    "bar_text" => "#FFFFFF",
  },
  "dracula" => {
    "primary" => "#BD93F9", "secondary" => "#8B5CF6", "accent" => "#FF79C6",
    "success" => "#50FA7B", "warning" => "#F1FA8C", "error" => "#FF5555",
    "text" => "#F8F8F2", "text_dim" => "#8895C7", "text_muted" => "#606888",
    "surface" => "#282A36", "border_dim" => "#44475A", "border_focus" => "#BD93F9",
    "bar_text" => "#FFFFFF",
  },
  "catppuccin" => {
    "primary" => "#CBA6F7", "secondary" => "#89B4FA", "accent" => "#F5C2E7",
    "success" => "#A6E3A1", "warning" => "#F9E2AF", "error" => "#F38BA8",
    "text" => "#CDD6F4", "text_dim" => "#9399B2", "text_muted" => "#6C7086",
    "surface" => "#1E1E2E", "border_dim" => "#313244", "border_focus" => "#CBA6F7",
    "bar_text" => "#1E1E2E",
  },
  "tokyo night" => {
    "primary" => "#7AA2F7", "secondary" => "#7DCFFF", "accent" => "#BB9AF7",
    "success" => "#9ECE6A", "warning" => "#E0AF68", "error" => "#F7768E",
    "text" => "#C0CAF5", "text_dim" => "#737AA2", "text_muted" => "#545C7E",
    "surface" => "#1A1B26", "border_dim" => "#33364E", "border_focus" => "#7AA2F7",
    "bar_text" => "#1A1B26",
  },
  "gruvbox" => {
    "primary" => "#FE8019", "secondary" => "#D79921", "accent" => "#FB4934",
    "success" => "#B8BB26", "warning" => "#FABD2F", "error" => "#CC241D",
    "text" => "#EBDBB2", "text_dim" => "#A89984", "text_muted" => "#7C6F64",
    "surface" => "#282828", "border_dim" => "#504945", "border_focus" => "#FE8019",
    "bar_text" => "#1D2021",
  },
  "nord" => {
    "primary" => "#88C0D0", "secondary" => "#5E81AC", "accent" => "#B48EAD",
    "success" => "#A3BE8C", "warning" => "#EBCB8B", "error" => "#BF616A",
    "text" => "#ECEFF4", "text_dim" => "#8FBCBB", "text_muted" => "#616E88",
    "surface" => "#2E3440", "border_dim" => "#434C5E", "border_focus" => "#88C0D0",
    "bar_text" => "#FFFFFF",
  },
  "rose pine" => {
    "primary" => "#C4A7E7", "secondary" => "#31748F", "accent" => "#EBBCBA",
    "success" => "#9CCFD8", "warning" => "#F6C177", "error" => "#EB6F92",
    "text" => "#E0DEF4", "text_dim" => "#908CAA", "text_muted" => "#6E6A86",
    "surface" => "#191724", "border_dim" => "#26233A", "border_focus" => "#C4A7E7",
    "bar_text" => "#FFFFFF",
  },
  "solarized" => {
    "primary" => "#268BD2", "secondary" => "#2AA198", "accent" => "#D33682",
    "success" => "#859900", "warning" => "#B58900", "error" => "#DC322F",
    "text" => "#93A1A1", "text_dim" => "#839496", "text_muted" => "#657B83",
    "surface" => "#002B36", "border_dim" => "#073642", "border_focus" => "#268BD2",
    "bar_text" => "#FDF6E3",
  },
  "light" => {
    "primary" => "#6C5CE7", "secondary" => "#0984E3", "accent" => "#E84393",
    "success" => "#00B894", "warning" => "#D4A017", "error" => "#D63031",
    "text" => "#2D3436", "text_dim" => "#636E72", "text_muted" => "#95A5A6",
    "surface" => "#F5F5F5", "border_dim" => "#DFE6E9", "border_focus" => "#6C5CE7",
    "bar_text" => "#FFFFFF",
  },
  "horizon" => {
    "primary" => "#FC4777", "secondary" => "#FF58B1", "accent" => "#FFA27B",
    "success" => "#00CE81", "warning" => "#FFA27B", "error" => "#FC4777",
    "text" => "#16161D", "text_dim" => "#6A5B58", "text_muted" => "#9B8C89",
    "surface" => "#FDF0ED", "border_dim" => "#F0D8D2", "border_focus" => "#FC4777",
    "bar_text" => "#FDF0ED",
  },
}.freeze

REQUIRED_THEME_KEYS = %w[primary secondary accent success warning error text text_dim text_muted surface border_dim border_focus bar_text].freeze

THEMES = BUILTIN_THEMES.dup
THEME_NAMES = THEMES.keys

# Dynamic theme module — reads from the active theme hash
module Theme
  CUSTOM_THEMES_DIR = File.join(CONFIG_DIR, "themes")

  @current = THEMES["midnight"]

  def self.set(name)
    @current = THEMES[name] || THEMES["midnight"]
  end

  def self.current_name
    THEMES.find { |k, v| v == @current }&.first || "midnight"
  end

  def self.PRIMARY;      @current["primary"]; end
  def self.SECONDARY;    @current["secondary"]; end
  def self.ACCENT;       @current["accent"]; end
  def self.SUCCESS;      @current["success"]; end
  def self.WARNING;      @current["warning"]; end
  def self.ERROR;        @current["error"]; end
  def self.TEXT;         @current["text"]; end
  def self.TEXT_DIM;     @current["text_dim"]; end
  def self.TEXT_MUTED;   @current["text_muted"]; end
  def self.SURFACE;      @current["surface"]; end
  def self.BORDER_DIM;   @current["border_dim"]; end
  def self.BORDER_FOCUS; @current["border_focus"]; end
  def self.BAR_TEXT;     @current["bar_text"]; end

  def self.gradient(c1, c2, steps)
    Lipgloss::ColorBlend.blends(c1, c2, steps, mode: Lipgloss::ColorBlend::HCL)
  rescue
    Array.new(steps) { c1 }
  end

  def self.gradient_text(text, c1, c2)
    chars = text.chars
    return text if chars.empty?
    colors = gradient(c1, c2, [chars.length, 2].max)
    chars.each_with_index.map { |ch, i|
      Lipgloss::Style.new.foreground(colors[[i, colors.length - 1].min]).render(ch)
    }.join
  end

  def self.load_custom_themes
    return unless File.directory?(CUSTOM_THEMES_DIR)

    Dir.glob(File.join(CUSTOM_THEMES_DIR, "*.yml")).sort.each do |path|
      name = File.basename(path, ".yml").tr("_-", "  ").gsub(/  +/, " ").strip
      next if name.empty?
      next if BUILTIN_THEMES.key?(name)

      data = YAML.safe_load(File.read(path))
      next unless data.is_a?(Hash)
      next unless REQUIRED_THEME_KEYS.all? { |k| data.key?(k) }

      THEMES[name] = data
    rescue
      next
    end

    THEME_NAMES.replace(THEMES.keys)
  end
end

Theme.load_custom_themes
