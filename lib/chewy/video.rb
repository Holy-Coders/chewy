# frozen_string_literal: true

class Chewy
  module Video
    private

    # Attempt to assemble frames into MP4 using ffmpeg.
    # Returns the output path on success, nil if ffmpeg is unavailable.
    def assemble_video_mp4(frame_paths, fps, output_path)
      return nil if frame_paths.empty?
      return nil unless system("which ffmpeg > /dev/null 2>&1")

      frames_dir = File.dirname(frame_paths.first)
      # Determine the frame filename pattern from the first frame
      basename = File.basename(frame_paths.first)
      # Replace the numeric portion with printf pattern (e.g., "20240101_120000_000.png" -> pattern)
      pattern = if basename =~ /^(.+?)(\d{3})(\.png)$/
        File.join(frames_dir, "#{$1}%03d#{$3}")
      else
        File.join(frames_dir, "%03d.png")
      end

      _out, _err, st = Open3.capture3(
        "ffmpeg", "-y", "-framerate", fps.to_s,
        "-i", pattern,
        "-c:v", "libx264", "-pix_fmt", "yuv420p",
        "-crf", "18", "-preset", "fast",
        output_path
      )
      st.success? ? output_path : nil
    rescue
      nil
    end

    def handle_video_done(message)
      @generating = false; @gen_pid = nil; @gen_start_time = nil

      @video_frame_paths = message.frame_paths || []
      @video_frames_dir = message.frames_dir
      @video_frame_index = 0
      @video_playing = false
      fps = @params[:fps] || 24
      @video_playback_fps = fps
      @video_playback_gen += 1

      # Try to assemble MP4
      mp4_path = File.join(message.frames_dir, "output.mp4")
      @video_mp4_path = assemble_video_mp4(@video_frame_paths, fps, mp4_path)

      # Set last output to first frame for main preview
      @last_output_path = @video_frame_paths.first if @video_frame_paths.any?
      @last_generation_time = message.elapsed
      @preview_cache = nil

      # Open video player overlay
      @overlay = :video_player
      clear_kitty_images if @kitty_graphics

      frame_count = @video_frame_paths.length
      duration = (frame_count.to_f / fps).round(1)
      [self, set_status_toast("Video: #{frame_count} frames, #{duration}s | #{message.elapsed}s")]
    end

    def handle_video_frame_tick(message)
      return [self, nil] unless @overlay == :video_player
      return [self, nil] unless message.generation == @video_playback_gen
      return [self, nil] unless @video_playing && @video_frame_paths.length > 0

      @video_frame_index = (@video_frame_index + 1) % @video_frame_paths.length
      @preview_cache = nil
      clear_kitty_images if @kitty_graphics

      # Schedule next frame
      [self, schedule_video_frame_tick]
    end

    def start_video_playback
      @video_playing = true
      @video_playback_gen += 1
      schedule_video_frame_tick
    end

    def stop_video_playback
      @video_playing = false
      @video_playback_gen += 1
      nil
    end

    def schedule_video_frame_tick
      gen = @video_playback_gen
      interval = 1.0 / @video_playback_fps
      Bubbletea.tick(interval) { VideoFrameTickMessage.new(generation: gen) }
    end

    def handle_video_player_key(message)
      key = message.to_s
      return [self, nil] if @video_frame_paths.empty?

      case key
      when "esc", "q"
        stop_video_playback
        clear_kitty_images if @kitty_graphics
        @overlay = nil
        @preview_cache = nil
        case @focus
        when FOCUS_PROMPT then @prompt_input.focus
        when FOCUS_NEGATIVE then @negative_input.focus
        end
        return [self, nil]
      when " "
        # Toggle play/pause
        if @video_playing
          stop_video_playback
          return [self, nil]
        else
          return [self, start_video_playback]
        end
      when "left", "h"
        stop_video_playback
        @video_frame_index = (@video_frame_index - 1) % @video_frame_paths.length
        @preview_cache = nil
        clear_kitty_images if @kitty_graphics
        return [self, nil]
      when "right", "l"
        stop_video_playback
        @video_frame_index = (@video_frame_index + 1) % @video_frame_paths.length
        @preview_cache = nil
        clear_kitty_images if @kitty_graphics
        return [self, nil]
      when "["
        @video_playback_fps = [@video_playback_fps - 2, 1].max
        return [self, nil]
      when "]"
        @video_playback_fps = [@video_playback_fps + 2, 60].min
        return [self, nil]
      when "home", "0"
        stop_video_playback
        @video_frame_index = 0
        @preview_cache = nil
        clear_kitty_images if @kitty_graphics
        return [self, nil]
      when "end", "$"
        stop_video_playback
        @video_frame_index = @video_frame_paths.length - 1
        @preview_cache = nil
        clear_kitty_images if @kitty_graphics
        return [self, nil]
      when "o"
        if @video_mp4_path && File.exist?(@video_mp4_path)
          open_image(@video_mp4_path)
        end
        return [self, nil]
      end
      [self, nil]
    end

    def render_video_player_view
      inner_w = @width - 4
      inner_h = @height - 4

      dim = Lipgloss::Style.new.foreground(Theme.TEXT_DIM)
      accent = Lipgloss::Style.new.foreground(Theme.ACCENT)
      primary = Lipgloss::Style.new.foreground(Theme.PRIMARY).bold(true)
      center = ->(s) { Lipgloss::Style.new.width(inner_w).align(:center).render(s) }

      frame_count = @video_frame_paths.length
      current = @video_frame_index || 0

      # Header
      play_state = @video_playing ? "\u25B6 Playing" : "\u23F8 Paused"
      header = center.call(
        "#{primary.render("Video Player")} #{dim.render("|")} " \
        "#{accent.render(play_state)} #{dim.render("|")} " \
        "Frame #{accent.render("#{current + 1}/#{frame_count}")} #{dim.render("|")} " \
        "#{accent.render("#{@video_playback_fps}")} fps"
      )

      # Render current frame
      img_h = [inner_h - 6, 4].max
      img_w = inner_w - 4
      frame_path = frame_count > 0 ? @video_frame_paths[current] : nil

      frame_img = if frame_path && File.exist?(frame_path)
        if @kitty_graphics
          render_image(frame_path, img_w, img_h, kitty_overlay: true)
        else
          render_image_halfblocks(frame_path, img_w, img_h, corner_radius: 3)
        end
      end

      frame_view = if frame_img
        @kitty_graphics ? frame_img : center_image(frame_img, inner_w)
      else
        center.call(dim.render("No frame available"))
      end

      if @kitty_graphics && frame_path && File.exist?(frame_path)
        # Whole-screen render adds 1 row / 2 cols of outer padding around the panel.
        # The panel itself has a border and 1x2 inner padding, and the frame area
        # starts after the header plus a spacer line.
        frame_row = 6
        frame_col = 8
        @kitty_overlay_pending = { path: frame_path, row: frame_row, col: frame_col, w: img_w, h: img_h, slot: 30, rounded: false }
      end

      # Progress bar
      pct = frame_count > 1 ? current.to_f / (frame_count - 1) : 0
      bar = @progress.view_as(pct.clamp(0.0, 1.0))
      progress_line = center.call(bar)

      # Controls
      mp4_hint = @video_mp4_path ? "  #{dim.render("o: open mp4")}" : ""
      controls = center.call(
        "#{dim.render("space: play/pause  \u2190\u2192: step  []: speed  0/$: start/end  q: close")}#{mp4_hint}"
      )

      content = [header, "", frame_view, "", progress_line, controls].join("\n")

      Lipgloss::Style.new
        .border(:rounded).border_foreground(gradient_border_color)
        .background(Theme.SURFACE)
        .width(inner_w).height(inner_h)
        .padding(1, 2)
        .render(content)
    end
  end
end
