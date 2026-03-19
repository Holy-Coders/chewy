#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/chewy"

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

# ---------- Entrypoint ----------

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
