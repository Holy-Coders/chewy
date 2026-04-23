# frozen_string_literal: true

class GenerationDoneMessage < Bubbletea::Message
  attr_reader :output_path, :elapsed, :stderr_output
  def initialize(output_path:, elapsed:, stderr_output: "")
    @output_path = output_path; @elapsed = elapsed; @stderr_output = stderr_output
  end
end

class RevealTickMessage < Bubbletea::Message
  attr_reader :phase
  def initialize(phase:) @phase = phase end
end

class SplashTickMessage < Bubbletea::Message
  attr_reader :phase
  def initialize(phase:) @phase = phase end
end

class GenerationErrorMessage < Bubbletea::Message
  attr_reader :error, :stderr_output
  def initialize(error:, stderr_output: "")
    @error = error; @stderr_output = stderr_output
  end
end

class ReposFetchedMessage < Bubbletea::Message
  attr_reader :repos
  def initialize(repos:) @repos = repos end
end

class ReposFetchErrorMessage < Bubbletea::Message
  attr_reader :error
  def initialize(error:) @error = error end
end

class FilesFetchedMessage < Bubbletea::Message
  attr_reader :files, :repo_id
  def initialize(files:, repo_id:) @files = files; @repo_id = repo_id end
end

class FilesFetchErrorMessage < Bubbletea::Message
  attr_reader :error
  def initialize(error:) @error = error end
end

class ModelDownloadDoneMessage < Bubbletea::Message
  attr_reader :path, :filename
  def initialize(path:, filename:) @path = path; @filename = filename end
end

class ModelDownloadErrorMessage < Bubbletea::Message
  attr_reader :error
  def initialize(error:) @error = error end
end

class CompanionDownloadDoneMessage < Bubbletea::Message
  attr_reader :name
  def initialize(name:) @name = name end
end

class CompanionDownloadErrorMessage < Bubbletea::Message
  attr_reader :name, :error
  def initialize(name:, error:) @name = name; @error = error end
end

class ClipboardPasteMessage < Bubbletea::Message
  attr_reader :path, :error
  def initialize(path: nil, error: nil) @path = path; @error = error end
end

class ClipboardCopyMessage < Bubbletea::Message
  attr_reader :error
  def initialize(error: nil) @error = error end
end

class StatusDismissMessage < Bubbletea::Message
  attr_reader :generation
  def initialize(generation:) @generation = generation end
end

class ErrorDismissMessage < Bubbletea::Message
  attr_reader :generation
  def initialize(generation:) @generation = generation end
end

class LoraDownloadDoneMessage < Bubbletea::Message
  attr_reader :path, :filename
  def initialize(path:, filename:) @path = path; @filename = filename end
end

class LoraDownloadErrorMessage < Bubbletea::Message
  attr_reader :error
  def initialize(error:) @error = error end
end

class LoraReposFetchedMessage < Bubbletea::Message
  attr_reader :repos
  def initialize(repos:) @repos = repos end
end

class LoraReposFetchErrorMessage < Bubbletea::Message
  attr_reader :error
  def initialize(error:) @error = error end
end

class LoraFilesFetchedMessage < Bubbletea::Message
  attr_reader :files, :repo_id
  def initialize(files:, repo_id:) @files = files; @repo_id = repo_id end
end

class LoraFilesFetchErrorMessage < Bubbletea::Message
  attr_reader :error
  def initialize(error:) @error = error end
end

class ModelValidatedMessage < Bubbletea::Message
  attr_reader :path, :model_type, :error
  def initialize(path:, model_type: nil, error: nil) @path = path; @model_type = model_type; @error = error end
end

class FilePickerPreviewMessage < Bubbletea::Message
  attr_reader :generation, :path, :thumb
  def initialize(generation:, path: nil, thumb: nil) @generation = generation; @path = path; @thumb = thumb end
end

class GalleryPreviewMessage < Bubbletea::Message
  attr_reader :generation, :path, :thumb
  def initialize(generation:, path: nil, thumb: nil) @generation = generation; @path = path; @thumb = thumb end
end

class StarterPackItemDoneMessage < Bubbletea::Message
  attr_reader :item_name
  def initialize(item_name:) @item_name = item_name end
end

class StarterPackItemErrorMessage < Bubbletea::Message
  attr_reader :item_name, :error
  def initialize(item_name:, error:) @item_name = item_name; @error = error end
end

class PromptEnhanceMessage < Bubbletea::Message
  attr_reader :text, :target, :error
  def initialize(text: nil, target:, error: nil) @text = text; @target = target; @error = error end
end

class VideoGenerationDoneMessage < Bubbletea::Message
  attr_reader :frames_dir, :frame_paths, :mp4_path, :elapsed, :stderr_output
  def initialize(frames_dir:, frame_paths:, mp4_path: nil, elapsed:, stderr_output: "")
    @frames_dir = frames_dir; @frame_paths = frame_paths; @mp4_path = mp4_path
    @elapsed = elapsed; @stderr_output = stderr_output
  end
end

class VideoFrameTickMessage < Bubbletea::Message
  attr_reader :generation
  def initialize(generation:) @generation = generation end
end

class UpscaleDoneMessage < Bubbletea::Message
  attr_reader :output_path, :elapsed
  def initialize(output_path:, elapsed:) @output_path = output_path; @elapsed = elapsed end
end

class UpscaleErrorMessage < Bubbletea::Message
  attr_reader :error
  def initialize(error:) @error = error end
end
