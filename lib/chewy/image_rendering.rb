# frozen_string_literal: true

class Chewy
  module ImageRendering
    private

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
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze

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

    def png_dimensions(path)
      header = File.binread(path, 24)
      return nil unless header && header.bytesize == 24
      return nil unless header.start_with?(PNG_SIGNATURE)
      return nil unless header.byteslice(12, 4) == "IHDR"

      header.byteslice(16, 8).unpack("NN")
    rescue
      nil
    end

    def kitty_image_payload(path, rounded: true)
      if !rounded && (dims = png_dimensions(path))
        return [dims[0], dims[1], File.binread(path)]
      end

      image = ChunkyPNG::Image.from_file(path)
      png_data = if rounded
        apply_rounded_corners!(image)
        image.to_blob
      else
        File.binread(path)
      end
      [image.width, image.height, png_data]
    end

    def kitty_fit_dimensions(img_w, img_h, max_w, max_h)
      cell_ratio = 2.0
      img_cols = img_w.to_f
      img_rows = img_h.to_f / cell_ratio
      scale = [max_w / img_cols, max_h / img_rows].min

      fit_cols = (img_cols * scale).floor.clamp(1, max_w)
      fit_rows = (img_rows * scale).floor.clamp(1, max_h)
      [fit_cols, fit_rows]
    end

    # slot: stable ID for this image position (avoids flicker on re-render)
    def render_image_kitty(path, max_w, max_h, slot: 1, rounded: true)
      return nil unless path && File.exist?(path) && File.size(path) > 0

      img_w, img_h, png_data = kitty_image_payload(path, rounded: rounded)
      encoded = Base64.strict_encode64(png_data)

      fit_cols, fit_rows = kitty_fit_dimensions(img_w, img_h, max_w, max_h)

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
      @_kitty_overlay_cache = nil
      @_kitty_overlay_cache_key = nil
    end

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
    # Caches the full overlay string by path+dimensions+position to avoid re-reading every frame.
    def build_kitty_overlay(req)
      path = req[:path]
      return "" unless path && File.exist?(path) && File.size(path) > 0
      rounded = req.fetch(:rounded, true)

      cache_key = [path, req[:w], req[:h], req[:slot], req[:row], req[:col], rounded]

      if @_kitty_overlay_cache_key == cache_key && @_kitty_overlay_cache
        return @_kitty_overlay_cache
      end

      slot = req[:slot]
      max_w = req[:w]; max_h = req[:h]

      img_w, img_h, png_data = kitty_image_payload(path, rounded: rounded)
      fit_cols, fit_rows = kitty_fit_dimensions(img_w, img_h, max_w, max_h)

      # Center the image within the target area
      col = req[:col] + [(max_w - fit_cols) / 2, 0].max
      row = req[:row] + [(max_h - fit_rows) / 2, 0].max

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

      @_kitty_overlay_cache = overlay
      @_kitty_overlay_cache_key = cache_key
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

    # Convert Theme.SURFACE hex color to ANSI 24-bit background escape sequence
    def surface_bg_escape
      hex = Theme.SURFACE.sub("#", "")
      r = hex[0, 2].to_i(16)
      g = hex[2, 2].to_i(16)
      b = hex[4, 2].to_i(16)
      "\e[48;2;#{r};#{g};#{b}m"
    end

    def hf_get(uri, limit = 5)
      raise "Too many redirects" if limit == 0
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.read_timeout = 30; http.open_timeout = 10
      req = Net::HTTP::Get.new(uri)
      req["Accept"] = "application/json"; req["User-Agent"] = "chewy-tui/1.0"
      resp = http.request(req)
      case resp
      when Net::HTTPRedirection then hf_get(URI.parse(resp["location"]), limit - 1)
      when Net::HTTPSuccess then resp
      else raise "HTTP #{resp.code}: #{resp.message}"
      end
    end

    def format_bytes(bytes)
      if bytes >= 1_073_741_824 then "%.1f GB" % (bytes.to_f / 1_073_741_824)
      elsif bytes >= 1_048_576 then "%.1f MB" % (bytes.to_f / 1_048_576)
      elsif bytes >= 1024 then "%.1f KB" % (bytes.to_f / 1024)
      else "#{bytes} B"
      end
    end

    def format_number(n)
      n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end

    # Calculate safe thread count based on current system load
    def safe_thread_count
      total = Etc.nprocessors
      if RUBY_PLATFORM.include?("darwin")
        # macOS: use sysctl for load average (1-minute)
        load_avg = `sysctl -n vm.loadavg 2>/dev/null`[/\{ ([\d.]+)/, 1]&.to_f || 0
      else
        # Linux: /proc/loadavg
        load_avg = (File.read("/proc/loadavg").split.first&.to_f rescue 0)
      end
      # Reserve cores proportional to current load
      # If load is 0, use all but 2. If load is high, scale down more.
      busy_cores = load_avg.ceil
      available = total - [busy_cores, 2].max
      available.clamp(1, total - 1)
    rescue
      [total - 2, 1].max
    end

    # Estimate available disk space in bytes for a given directory
    def estimate_available_disk_space(dir)
      output, _ = Open3.capture2("df", "-k", dir)
      available_kb = output.lines[1]&.split&.[](3)&.to_i || 0
      available_kb * 1024
    rescue
      0
    end

    # Estimate available system memory in bytes
    def estimate_available_memory
      if RUBY_PLATFORM.include?("darwin")
        # macOS: use vm_stat to get free + inactive pages
        output = `vm_stat 2>/dev/null`
        page_size = output[/page size of (\d+)/, 1]&.to_i || 16384
        free = output[/Pages free:\s+(\d+)/, 1]&.to_i || 0
        inactive = output[/Pages inactive:\s+(\d+)/, 1]&.to_i || 0
        (free + inactive) * page_size
      else
        # Linux: use /proc/meminfo
        meminfo = File.read("/proc/meminfo") rescue ""
        available = meminfo[/MemAvailable:\s+(\d+)/, 1]&.to_i
        available ? available * 1024 : 0
      end
    rescue
      0  # can't determine — skip the check
    end

    # Generate an inpainting mask with a center oval preserved (black) and edges regenerated (white).
    # Feathered edge prevents hard seam artifacts.
    def generate_center_preserve_mask(width, height, output_path, oval_pct: 0.35)
      mask = ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::WHITE)
      cx = width / 2.0
      cy = height / 2.0
      rx = width * oval_pct
      ry = height * oval_pct

      height.times do |y|
        width.times do |x|
          dx = (x - cx) / rx
          dy = (y - cy) / ry
          dist = Math.sqrt(dx * dx + dy * dy)
          if dist <= 1.0
            mask[x, y] = ChunkyPNG::Color::BLACK
          elsif dist < 1.15
            t = ((dist - 1.0) / 0.15).clamp(0.0, 1.0)
            gray = (t * 255).to_i
            mask[x, y] = ChunkyPNG::Color.rgb(gray, gray, gray)
          end
        end
      end

      mask.save(output_path)
      output_path
    end

    # Build a grid representation of the init image for the mask painter.
    # Returns an array of rows, each row an array of [r, g, b] averaged colors.
    def build_paint_grid(path, cols, rows)
      return nil unless path && File.exist?(path)
      image = ChunkyPNG::Image.from_file(path)
      cell_w = image.width.to_f / cols
      cell_h = image.height.to_f / rows

      rows.times.map do |row|
        cols.times.map do |col|
          # Sample center pixel of each cell
          sx = ((col + 0.5) * cell_w).to_i.clamp(0, image.width - 1)
          sy = ((row + 0.5) * cell_h).to_i.clamp(0, image.height - 1)
          pixel = image[sx, sy]
          [ChunkyPNG::Color.r(pixel), ChunkyPNG::Color.g(pixel), ChunkyPNG::Color.b(pixel)]
        end
      end
    rescue
      nil
    end

    # Convert a boolean grid (true = regenerate/white, false = keep/black) to a mask PNG.
    def grid_to_mask(grid, width, height, output_path)
      grid_rows = grid.length
      grid_cols = grid.first.length
      mask = ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::BLACK)
      cell_w = width.to_f / grid_cols
      cell_h = height.to_f / grid_rows

      grid_rows.times do |row|
        grid_cols.times do |col|
          next unless grid[row][col]
          x0 = (col * cell_w).to_i
          y0 = (row * cell_h).to_i
          x1 = [((col + 1) * cell_w).to_i, width].min
          y1 = [((row + 1) * cell_h).to_i, height].min
          (y0...y1).each do |y|
            (x0...x1).each do |x|
              mask[x, y] = ChunkyPNG::Color::WHITE
            end
          end
        end
      end

      # Feather edges with a box blur for smooth transitions (prevents hard seams)
      # Use a larger radius for better blending at generation boundaries
      radius = [width, height].min / 32  # ~16px for 512, ~32px for 1024
      radius = radius.clamp(4, 40)

      # Horizontal pass
      blurred = mask.dup
      height.times do |y|
        running = 0
        count = 0
        # Initialize window
        (0..[radius, width - 1].min).each do |x|
          running += ChunkyPNG::Color.r(mask[x, y])
          count += 1
        end
        width.times do |x|
          blurred[x, y] = ChunkyPNG::Color.rgb(running / count, running / count, running / count)
          # Expand right
          rx = x + radius + 1
          if rx < width
            running += ChunkyPNG::Color.r(mask[rx, y])
            count += 1
          end
          # Shrink left
          lx = x - radius
          if lx >= 0
            running -= ChunkyPNG::Color.r(mask[lx, y])
            count -= 1
          end
        end
      end

      # Vertical pass
      result = blurred.dup
      width.times do |x|
        running = 0
        count = 0
        (0..[radius, height - 1].min).each do |y|
          running += ChunkyPNG::Color.r(blurred[x, y])
          count += 1
        end
        height.times do |y|
          result[x, y] = ChunkyPNG::Color.rgb(running / count, running / count, running / count)
          by = y + radius + 1
          if by < height
            running += ChunkyPNG::Color.r(blurred[x, by])
            count += 1
          end
          ty = y - radius
          if ty >= 0
            running -= ChunkyPNG::Color.r(blurred[x, ty])
            count -= 1
          end
        end
      end

      result.save(output_path)
      output_path
    end
  end
end
