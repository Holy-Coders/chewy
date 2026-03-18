# frozen_string_literal: true

module Chewy::FilePicker
  IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .webp .bmp].freeze
  MODEL_PICKER_EXTENSIONS = %w[.gguf .safetensors .ckpt .pth].freeze

  private

  def open_file_picker
    open_file_picker_for(:init_image)
  end

  def open_file_picker_for(target)
    @file_picker_target = target
    case @focus
    when FOCUS_PROMPT then @prompt_input.blur
    when FOCUS_NEGATIVE then @negative_input.blur
    end
    @overlay = :file_picker
    @error_message = nil
    @file_picker_dir = case target
    when :init_image
      if @init_image_path then File.dirname(@init_image_path)
      elsif File.directory?(@output_dir) then File.expand_path(@output_dir)
      else File.expand_path("~")
      end
    when :controlnet
      if @controlnet_image_path then File.dirname(@controlnet_image_path)
      elsif File.directory?(@output_dir) then File.expand_path(@output_dir)
      else File.expand_path("~")
      end
    else
      File.expand_path("~")
    end
    scan_file_picker_dir
    [self, nil]
  end

  def open_controlnet_model_picker
    @file_picker_target = :cn_model
    case @focus
    when FOCUS_PROMPT then @prompt_input.blur
    when FOCUS_NEGATIVE then @negative_input.blur
    end
    @overlay = :file_picker
    @error_message = nil
    @file_picker_dir = if @controlnet_model_path
      File.dirname(@controlnet_model_path)
    else
      @models_dir || File.expand_path("~/models")
    end
    scan_file_picker_dir
    [self, nil]
  end

  def paste_image_from_clipboard
    @status_message = "Reading clipboard..."
    output_dir = @output_dir
    FileUtils.mkdir_p(output_dir)

    cmd = Proc.new do
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
      dest = File.join(output_dir, ".clipboard_#{timestamp}.png")

      if RUBY_PLATFORM.include?("darwin")
        # macOS: use osascript to extract clipboard image as PNG
        script = <<~APPLESCRIPT
          try
            set imgData to the clipboard as «class PNGf»
            set filePath to POSIX file "#{dest}"
            set fileRef to open for access filePath with write permission
            write imgData to fileRef
            close access fileRef
            return "ok"
          on error errMsg
            return "error:" & errMsg
          end try
        APPLESCRIPT
        result, status = Open3.capture2("osascript", "-e", script)
        result = result.strip

        if result == "ok" && File.exist?(dest) && File.size(dest) > 0
          ClipboardPasteMessage.new(path: dest)
        else
          File.delete(dest) if File.exist?(dest)
          err = result.start_with?("error:") ? result.sub("error:", "") : "No image on clipboard"
          ClipboardPasteMessage.new(error: err)
        end
      else
        # Linux: try xclip
        _, status = Open3.capture2("xclip", "-selection", "clipboard", "-t", "image/png", "-o", out: dest)
        if status.success? && File.exist?(dest) && File.size(dest) > 0
          ClipboardPasteMessage.new(path: dest)
        else
          File.delete(dest) if File.exist?(dest)
          ClipboardPasteMessage.new(error: "No image on clipboard (need xclip)")
        end
      end
    rescue => e
      File.delete(dest) rescue nil if dest
      ClipboardPasteMessage.new(error: e.message)
    end

    [self, cmd]
  end

  # Read text from the system clipboard
  def read_clipboard_text
    if RUBY_PLATFORM.include?("darwin")
      `pbpaste 2>/dev/null`.strip rescue ""
    else
      text = `wl-paste --no-newline 2>/dev/null`.strip rescue ""
      return text unless text.empty?
      text = `xclip -selection clipboard -o 2>/dev/null`.strip rescue ""
      return text unless text.empty?
      `xsel --clipboard --output 2>/dev/null`.strip rescue ""
    end
  end

  # Paste text from clipboard into the given input at its cursor position
  def paste_text_into(input)
    clip = read_clipboard_text
    return [self, nil] if clip.empty?

    current = input.value
    pos = input.position
    input.value = current[0...pos].to_s + clip + current[pos..].to_s
    input.position = pos + clip.length
    [self, set_status_toast("Pasted #{clip.length} chars")]
  end

  def scan_file_picker_dir
    entries = []
    # Parent directory entry
    parent = File.dirname(@file_picker_dir)
    entries << { name: "..", path: parent, type: :dir } unless parent == @file_picker_dir

    begin
      Dir.entries(@file_picker_dir).sort.each do |name|
        next if name == "." || name == ".."
        next if name.start_with?(".")  # skip hidden files
        full = File.join(@file_picker_dir, name)

        if File.directory?(full)
          entries << { name: "#{name}/", path: full, type: :dir }
        else
          ext = File.extname(name).downcase
          allowed = @file_picker_target == :cn_model ? MODEL_EXTENSIONS : IMAGE_EXTENSIONS
          if allowed.include?(ext)
            size = File.size(full) rescue 0
            entries << { name: name, path: full, type: :file, size: size }
          end
        end
      end
    rescue Errno::EACCES
      @error_message = "Permission denied: #{@file_picker_dir}"
    end

    @file_picker_entries = entries
    @file_picker_index = 0
    @file_picker_scroll = 0
    @file_picker_thumb_cache = {}
  end
end
