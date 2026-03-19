# frozen_string_literal: true

module Chewy::ImageRendering
  KITTY_PLACEHOLDER = "\u{10EEEE}".freeze
  # Combining diacritical marks for encoding row/column indices in kitty placeholders.
  # From the Kitty graphics protocol spec — zero-width combining characters.
  KITTY_DIACRITICS = [
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F,
    0x0346, 0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0353,
    0x0354, 0x0355, 0x0357, 0x0358, 0x035B, 0x035D, 0x035E, 0x0360,
    0x0361, 0x0362, 0x0338, 0x0337, 0x0489,
    0x20D0, 0x20D1, 0x20D2, 0x20D3, 0x20D4, 0x20D5, 0x20D6, 0x20D7,
    0x20DB, 0x20DC, 0x20E1, 0x20E7, 0x20E9, 0x20EA, 0x20EB, 0x20EC,
    0x20ED, 0x20EE, 0x20EF, 0x20F0,
  ].freeze

  private

  # Center a rendered image (with ANSI escape codes) horizontally within a given width
  def center_image(img_str, target_width)
    return img_str unless img_str
    lines = img_str.split("\n")
    return img_str if lines.empty?
    # Measure visible width of first line (strip ANSI escapes)
    visible_width = lines.first.gsub(/\e\[[0-9;]*[A-Za-z]/, "").length
    pad = [(target_width - visible_width) / 2, 0].max
    padding = " " * pad
    lines.map { |l| "#{padding}#{l}" }.join("\n")
  end

  # Theme-aware logo renderer: transparent pixels -> surface color,
  # dark strokes -> white on dark themes, black on light themes.
  def render_logo_halfblocks(path, max_w, max_h, pixelate: nil)
    return nil unless path && File.exist?(path)

    image = ChunkyPNG::Image.from_file(path)
    pixel_h = max_h * 2

    scale_w = max_w.to_f / image.width
    scale_h = pixel_h.to_f / image.height
    scale = [scale_w, scale_h].min

    new_w = (image.width * scale).to_i.clamp(1, max_w)
    new_h = (image.height * scale).to_i.clamp(1, pixel_h)

    resized = image.resample_nearest_neighbor(new_w, new_h)

    if pixelate && pixelate > 1
      tiny_w = [new_w / pixelate, 2].max
      tiny_h = [new_h / pixelate, 2].max
      tiny = resized.resample_nearest_neighbor(tiny_w, tiny_h)
      resized = tiny.resample_nearest_neighbor(new_w, new_h)
    end

    # Parse surface color for background
    surf = Theme.SURFACE.delete("#")
    sr = surf[0..1].to_i(16); sg = surf[2..3].to_i(16); sb = surf[4..5].to_i(16)
    # Dark theme if surface luminance is low
    dark_theme = (0.299 * sr + 0.587 * sg + 0.114 * sb) / 255.0 < 0.5

    lines = []
    y = 0
    while y < new_h
      line = +""
      new_w.times do |x|
        top = resized[x, y]
        bottom = (y + 1 < new_h) ? resized[x, y + 1] : ChunkyPNG::Color::TRANSPARENT

        tr, tg, tb = logo_pixel_color(top, sr, sg, sb, dark_theme)
        br, bg_, bb = logo_pixel_color(bottom, sr, sg, sb, dark_theme)

        line << "\e[38;2;#{tr};#{tg};#{tb}m\e[48;2;#{br};#{bg_};#{bb}m\u2580\e[0m"
      end
      lines << line
      y += 2
    end

    lines.join("\n")
  rescue
    nil
  end

  def logo_pixel_color(pixel, sr, sg, sb, dark_theme)
    a = ChunkyPNG::Color.a(pixel)
    if a < 128
      [sr, sg, sb]
    else
      if dark_theme
        [255 - ChunkyPNG::Color.r(pixel), 255 - ChunkyPNG::Color.g(pixel), 255 - ChunkyPNG::Color.b(pixel)]
      else
        [ChunkyPNG::Color.r(pixel), ChunkyPNG::Color.g(pixel), ChunkyPNG::Color.b(pixel)]
      end
    end
  end

  def render_image_halfblocks(path, max_w, max_h, pixelate: nil, corner_radius: 0)
    return nil unless path && File.exist?(path)

    image = ChunkyPNG::Image.from_file(path)
    pixel_h = max_h * 2 # each row = 2 vertical pixels

    scale_w = max_w.to_f / image.width
    scale_h = pixel_h.to_f / image.height
    scale = [scale_w, scale_h].min

    new_w = (image.width * scale).to_i.clamp(1, max_w)
    new_h = (image.height * scale).to_i.clamp(1, pixel_h)

    resized = image.resample_nearest_neighbor(new_w, new_h)

    # Pixelation effect: downsample then scale back up for blocky look
    if pixelate && pixelate > 1
      tiny_w = [new_w / pixelate, 2].max
      tiny_h = [new_h / pixelate, 2].max
      tiny = resized.resample_nearest_neighbor(tiny_w, tiny_h)
      resized = tiny.resample_nearest_neighbor(new_w, new_h)
    end

    total_rows = (new_h + 1) / 2
    r = corner_radius

    lines = []
    y = 0
    row = 0
    while y < new_h
      line = +""
      new_w.times do |x|
        if r > 0 && corner_blank?(x, row, new_w, total_rows, r)
          line << " "
        else
          top = resized[x, y]
          bottom = (y + 1 < new_h) ? resized[x, y + 1] : ChunkyPNG::Color::BLACK

          tr = ChunkyPNG::Color.r(top)
          tg = ChunkyPNG::Color.g(top)
          tb = ChunkyPNG::Color.b(top)
          br = ChunkyPNG::Color.r(bottom)
          bg_ = ChunkyPNG::Color.g(bottom)
          bb = ChunkyPNG::Color.b(bottom)

          line << "\e[38;2;#{tr};#{tg};#{tb}m\e[48;2;#{br};#{bg_};#{bb}m\u2580\e[0m"
        end
      end
      lines << line
      y += 2
      row += 1
    end

    lines.join("\n")
  rescue
    nil
  end

  def corner_blank?(x, row, width, height, radius)
    # Top-left
    if x < radius && row < radius
      dx = radius - x - 0.5
      dy = radius - row - 0.5
      return dx * dx + dy * dy > radius * radius
    end
    # Top-right
    if x >= width - radius && row < radius
      dx = x - (width - radius) + 0.5
      dy = radius - row - 0.5
      return dx * dx + dy * dy > radius * radius
    end
    # Bottom-left
    if x < radius && row >= height - radius
      dx = radius - x - 0.5
      dy = row - (height - radius) + 0.5
      return dx * dx + dy * dy > radius * radius
    end
    # Bottom-right
    if x >= width - radius && row >= height - radius
      dx = x - (width - radius) + 0.5
      dy = row - (height - radius) + 0.5
      return dx * dx + dy * dy > radius * radius
    end
    false
  end

  # Apply anti-aliased rounded corners to a ChunkyPNG image.
  # radius_pct is the corner radius as a percentage of the shorter dimension (0.0-0.5).
  def apply_rounded_corners!(image, radius_pct: 0.04)
    w = image.width; h = image.height
    r = ([w, h].min * radius_pct).round.to_f
    return if r < 2

    ri = r.to_i + 1
    ri.times do |dy|
      ri.times do |dx|
        # Distance from pixel center to corner circle center
        cx = r - dx - 0.5
        cy = r - dy - 0.5
        dist = Math.sqrt(cx * cx + cy * cy)
        next if dist <= r - 1.0  # fully inside the curve

        # Anti-alias: blend alpha over a 1px transition band
        alpha = if dist >= r
                  0  # fully outside
                else
                  ((r - dist) * 255).round.clamp(0, 255)
                end

        corners = [
          [dx, dy],                   # top-left
          [w - 1 - dx, dy],           # top-right
          [dx, h - 1 - dy],           # bottom-left
          [w - 1 - dx, h - 1 - dy],   # bottom-right
        ]
        corners.each do |px, py|
          next if px < 0 || py < 0 || px >= w || py >= h
          if alpha == 0
            image[px, py] = ChunkyPNG::Color::TRANSPARENT
          else
            orig = image[px, py]
            orig_a = ChunkyPNG::Color.a(orig)
            new_a = (orig_a * alpha / 255).clamp(0, 255)
            image[px, py] = ChunkyPNG::Color.rgba(
              ChunkyPNG::Color.r(orig),
              ChunkyPNG::Color.g(orig),
              ChunkyPNG::Color.b(orig),
              new_a
            )
          end
        end
      end
    end
  end

  def gradient_border_color
    colors = Theme.gradient(Theme.PRIMARY, Theme.ACCENT, 3)
    colors[1] # midpoint blend of primary and accent
  end

  # slot: stable ID for this image position (avoids flicker on re-render)
  def render_image_kitty(path, max_w, max_h, slot: 1, rounded: true)
    return nil unless path && File.exist?(path) && File.size(path) > 0

    image = ChunkyPNG::Image.from_file(path)
    if rounded
      apply_rounded_corners!(image)
      png_data = image.to_blob
    else
      png_data = File.binread(path)
    end
    encoded = Base64.strict_encode64(png_data)

    # Compute cols/rows that fit within max_w × max_h while preserving aspect ratio.
    # Terminal cells are ~2x taller than wide (e.g. 8px × 16px).
    cell_ratio = 2.0
    img_w = image.width.to_f
    img_h = image.height.to_f

    # Convert image dimensions to "cell units" (cols and rows)
    # 1 col of image = 1 cell width, 1 row of image = cell_ratio cell widths of height
    img_cols = img_w
    img_rows = img_h / cell_ratio  # in cell-equivalent units

    scale_c = max_w / img_cols
    scale_r = max_h / img_rows
    scale = [scale_c, scale_r].min

    fit_cols = (img_cols * scale).floor.clamp(1, max_w)
    fit_rows = (img_rows * scale).floor.clamp(1, max_h)

    # Delete previous image in this slot, then transmit+display
    result = +"\e_Ga=d,d=I,i=#{slot},q=2\e\\"

    # Pass both c and r to hard-cap within bounds. The terminal fits the image
    # within this cell rectangle, preserving aspect ratio internally.
    # f=100=PNG, a=T=transmit+display, q=2=suppress responses
    chunks = encoded.scan(/.{1,4096}/)
    chunks.each_with_index do |chunk, i|
      more = (i < chunks.length - 1) ? 1 : 0
      if i == 0
        result << "\e_Gf=100,a=T,c=#{fit_cols},r=#{fit_rows},i=#{slot},q=2,m=#{more};#{chunk}\e\\"
      else
        result << "\e_Gm=#{more};#{chunk}\e\\"
      end
    end

    # Reserve rows so bubbletea accounts for image height
    result << ("\n" * [fit_rows - 1, 0].max)
    result
  rescue
    nil
  end

  def clear_kitty_images
    # Delete all kitty images - used when switching views
    print "\e_Ga=d,d=A,q=2\e\\"
  end

  # Kitty unicode placeholder inline renderer
  # Transmits the image to the terminal, then returns a string of U+10EEEE
  # placeholder characters that lipgloss can measure as normal text.
  # The terminal replaces those cells with actual image pixels.

  def render_image_kitty_inline(path, max_w, max_h)
    return nil unless @kitty_graphics
    return nil unless path && File.exist?(path) && File.size(path) > 0

    png_data = File.binread(path)
    image = ChunkyPNG::Image.from_file(path)

    # Compute fit dimensions
    cell_ratio = 2.0
    img_cols = image.width.to_f
    img_rows = image.height.to_f / cell_ratio

    scale_c = max_w / img_cols
    scale_r = max_h / img_rows
    scale = [scale_c, scale_r].min

    fit_cols = (img_cols * scale).floor.clamp(1, max_w)
    fit_rows = (img_rows * scale).floor.clamp(1, max_h)
    # Clamp to diacritics table size
    fit_rows = [fit_rows, KITTY_DIACRITICS.length].min
    fit_cols = [fit_cols, KITTY_DIACRITICS.length].min

    # Unique image ID (1-based, fits in 24-bit color)
    @kitty_image_id = (@kitty_image_id % 0xFFFFFE) + 1
    img_id = @kitty_image_id

    # Step 1: Transmit image data (a=t = store only)
    encoded = Base64.strict_encode64(png_data)
    chunks = encoded.scan(/.{1,4096}/)
    chunks.each_with_index do |chunk, i|
      more = (i < chunks.length - 1) ? 1 : 0
      if i == 0
        $stdout.write "\e_Gf=100,a=t,i=#{img_id},q=2,m=#{more};#{chunk}\e\\"
      else
        $stdout.write "\e_Gm=#{more};#{chunk}\e\\"
      end
    end

    # Step 2: Create virtual placement
    $stdout.write "\e_Ga=p,U=1,i=#{img_id},c=#{fit_cols},r=#{fit_rows},q=2\e\\"
    $stdout.flush

    # Encode image ID as RGB foreground color
    id_r = (img_id >> 16) & 0xFF
    id_g = (img_id >> 8) & 0xFF
    id_b = img_id & 0xFF

    # Step 3: Build placeholder grid — explicit row+col diacritics on every cell
    lines = fit_rows.times.map do |row|
      row_diac = KITTY_DIACRITICS[row]
      line = +"\e[38;2;#{id_r};#{id_g};#{id_b}m"
      fit_cols.times do |col|
        col_diac = KITTY_DIACRITICS[col]
        line << KITTY_PLACEHOLDER << [row_diac, col_diac].pack("UU")
      end
      line << "\e[39m"
      line
    end

    lines.join("\n")
  rescue
    nil
  end

  # Build a kitty overlay string: cursor-position + display image + restore cursor.
  # Appended to the view string AFTER lipgloss, so APC escapes don't affect layout.
  def build_kitty_overlay(req)
    path = req[:path]
    return "" unless path && File.exist?(path) && File.size(path) > 0

    image = ChunkyPNG::Image.from_file(path)
    cell_ratio = 2.0
    img_cols = image.width.to_f
    img_rows = image.height.to_f / cell_ratio
    max_h = req[:h]
    max_w = req[:w]
    scale = [max_w / img_cols, max_h / img_rows].min
    fit_cols = (img_cols * scale).floor.clamp(1, max_w)
    fit_rows = (img_rows * scale).floor.clamp(1, max_h)

    # Center the image within the target area
    col = req[:col] + [(max_w - fit_cols) / 2, 0].max
    row = req[:row] + [(max_h - fit_rows) / 2, 0].max

    # Apply rounded corners at the pixel level
    apply_rounded_corners!(image)
    png_data = image.to_blob

    slot = req[:slot]
    encoded = Base64.strict_encode64(png_data)
    chunks = encoded.scan(/.{1,4096}/)

    overlay = +""
    overlay << "\e_Ga=d,d=I,i=#{slot},q=2\e\\"  # delete previous
    overlay << "\e[s"                              # save cursor
    overlay << "\e[#{row};#{col}H"                 # move to position

    chunks.each_with_index do |chunk, i|
      more = (i < chunks.length - 1) ? 1 : 0
      if i == 0
        overlay << "\e_Gf=100,a=T,c=#{fit_cols},r=#{fit_rows},i=#{slot},q=2,m=#{more};#{chunk}\e\\"
      else
        overlay << "\e_Gm=#{more};#{chunk}\e\\"
      end
    end

    overlay << "\e[u"  # restore cursor
    overlay
  rescue
    ""
  end

  def render_image(path, max_w, max_h, pixelate: nil, corner_radius: 0, kitty_overlay: false)
    # When kitty overlay will handle this image, return blank space for layout only.
    if kitty_overlay && @kitty_graphics
      return ("\n" * [max_h - 1, 0].max)
    end
    render_image_halfblocks(path, max_w, max_h, pixelate: pixelate, corner_radius: corner_radius)
  end
end
