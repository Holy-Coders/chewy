#!/usr/bin/env ruby
# frozen_string_literal: true

require "bubbletea"
require "lipgloss"
require "bubbles"
require "open3"
require "fileutils"
require "net/http"
require "json"
require "uri"
require "yaml"
require "chunky_png"
require "pty"
require "base64"
require "etc"

# Load all chewy modules
require_relative "lib/chewy/version"
require_relative "lib/chewy/constants"
require_relative "lib/chewy/themes"
require_relative "lib/chewy/messages"

require_relative "lib/chewy/provider/base"
require_relative "lib/chewy/provider/local_sd_cpp"
require_relative "lib/chewy/provider/openai_images"
require_relative "lib/chewy/provider/huggingface_inference"
require_relative "lib/chewy/provider/gemini"
require_relative "lib/chewy/provider/openai_compatible"
require_relative "lib/chewy/provider/a1111"

require_relative "lib/chewy/http"
require_relative "lib/chewy/app/config"
require_relative "lib/chewy/app/models"
require_relative "lib/chewy/app/loras"
require_relative "lib/chewy/app/generation"
require_relative "lib/chewy/app/input_handling"
require_relative "lib/chewy/app/overlays"
require_relative "lib/chewy/app/downloads"
require_relative "lib/chewy/app/presets"
require_relative "lib/chewy/app/file_picker"
require_relative "lib/chewy/app/image_rendering"
require_relative "lib/chewy/app/views/main"
require_relative "lib/chewy/app/views/inputs"
require_relative "lib/chewy/app/views/overlays"

require_relative "lib/chewy/app"
require_relative "lib/chewy/cli"

run_cli
