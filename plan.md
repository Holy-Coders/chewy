# Plan: Organize chewy.rb into Multi-File Ruby Structure

## Current State
- Single file `chewy.rb` at ~2900 lines (actually ~7300 lines based on exploration)
- Contains: constants, themes, 20+ message classes, 6 provider implementations, the main `Chewy` TUI class (~5600 lines), CLI helpers, and entry point

## Proposed Structure

```
chewy.rb                          # Entry point (stays as `ruby chewy.rb`)
lib/
  chewy/
    version.rb                    # CHEWY_VERSION, CHEWY_REPO
    constants.rb                  # API bases, extensions, samplers, schedulers, config paths,
                                  #   BUILTIN_PRESETS, MODEL_FAMILIES, MODEL_FAMILY_LOOKUP,
                                  #   MODEL_BEST_SETTINGS, IMG2IMG_BEST_SETTINGS,
                                  #   FLUX_COMPANION_FILES, PRELOADED_MODELS,
                                  #   RECOMMENDED_LORAS, focus constants, CHEWY_LOGO
    themes.rb                     # THEMES hash + Theme module (set, accessors, gradient helpers)
    messages.rb                   # All message structs/classes (GenerationDoneMessage, etc.)
    provider/
      base.rb                    # Provider::Capabilities, ::GenerationRequest, ::GenerationResult, ::Base
      local_sd_cpp.rb            # LocalSdCppProvider
      openai_images.rb           # OpenAIImagesProvider
      huggingface_inference.rb   # HuggingFaceInferenceProvider
      gemini.rb                  # GeminiProvider
      openai_compatible.rb       # OpenAICompatibleProvider
      a1111.rb                   # A1111Provider
    app.rb                       # Main Chewy class - initialize, init, update, view + includes
    app/
      config.rb                  # Module Chewy::Config - load_config, save_config, load_presets,
                                 #   save_presets, build_providers, update_param_keys
      input_handling.rb          # Module Chewy::InputHandling - all handle_*_key, handle_mouse,
                                 #   forward_to_focused, cycle_focus
      generation.rb              # Module Chewy::Generation - start_generation, open_image,
                                 #   flux helpers, companion downloads
      models.rb                  # Module Chewy::Models - scan_models, scan_api_models,
                                 #   model_type_tag, detect_model_type, model_family_for,
                                 #   validate_model_cmd, toggle_pin, add_recent_model, delete_selected_model
      loras.rb                   # Module Chewy::Loras - scan_loras, filter_loras,
                                 #   detect_lora_family, lora_compatible?, toggle_lora_selection,
                                 #   adjust_lora_weight, lora metadata helpers
      overlays.rb                # Module Chewy::Overlays - toggle_overlay, open_overlay,
                                 #   close_overlay
      downloads.rb               # Module Chewy::Downloads - enter_download_mode,
                                 #   fetch_repos_cmd, fetch_files_cmd, start_model_download,
                                 #   all CivitAI/HF search, lora download mode
      presets.rb                 # Module Chewy::Presets - all_presets, load_preset,
                                 #   save_user_preset, delete_preset_at, select_model_by_type
      file_picker.rb             # Module Chewy::FilePicker - open_file_picker,
                                 #   scan_file_picker_dir, paste_image_from_clipboard,
                                 #   clipboard helpers
      image_rendering.rb         # Module Chewy::ImageRendering - render_image_halfblocks,
                                 #   render_image_kitty, render_image_kitty_inline,
                                 #   build_kitty_overlay, clear_kitty_images,
                                 #   corner helpers, render_image, render_logo_halfblocks
      views/
        main.rb                  # Module Chewy::Views::Main - render_main_view, render_header,
                                 #   render_left_panel, render_right_panel, render_image_preview,
                                 #   render_generating_preview, render_empty_preview,
                                 #   render_bottom_bar, context_keys
        inputs.rb                # Module Chewy::Views::Inputs - render_prompt_section,
                                 #   render_negative_section, render_params_section,
                                 #   render_wrapped_input, render_chips, chip helpers
        overlays.rb              # Module Chewy::Views::Overlays - render_models_content,
                                 #   render_download_view, render_gallery_view,
                                 #   render_fullscreen_image, render_lora_content,
                                 #   render_preset_content, render_help_view,
                                 #   render_theme_content, render_provider_content,
                                 #   render_api_key_content, render_hf_token_content,
                                 #   render_overlay_panel, render_splash
    cli.rb                       # CLI helpers: cli_fg, print_logo, check_for_updates,
                                 #   cli_list_images, cli_delete_image
    http.rb                      # hf_get helper (shared HTTP utility)
```

## Key Decisions

1. **Entry point stays `chewy.rb`** — `ruby chewy.rb` still works. It requires everything from `lib/` and runs the CLI/TUI.

2. **Chewy class uses `include` modules, not inheritance** — The main class includes mixins for concerns (config, input, generation, views, etc.). This keeps all state in one object (required by Elm architecture) while organizing code by responsibility.

3. **Providers get their own files** — Each is self-contained (~100-250 lines each). Clean separation.

4. **Views split into 3 files** — Main view, input rendering, and overlay rendering. These are the largest rendering sections.

5. **No unnecessary abstractions** — We're just splitting code into files with modules for namespacing. No new classes, no new patterns, no wrappers. The architecture stays identical.

6. **Constants consolidated into 2 files** — `version.rb` (tiny, used by CLI independently) and `constants.rb` (everything else). Themes get their own file since they include the `Theme` module.

## Cleanup Opportunities

While splitting, clean up:
- Remove any dead/unreachable code paths found during splitting
- Consolidate duplicate patterns (e.g., download mode for models vs LoRAs share similar flow)
- Ensure consistent method ordering within each module
- Remove redundant comments that just restate the code

## Implementation Order

1. Create `lib/chewy/` directory structure
2. Extract `version.rb` and `constants.rb`
3. Extract `themes.rb` and `messages.rb`
4. Extract all providers (`provider/*.rb`)
5. Extract Chewy class modules (`app/*.rb` and `app/views/*.rb`)
6. Create `app.rb` (Chewy class with includes and core methods)
7. Extract `cli.rb` and `http.rb`
8. Rewrite `chewy.rb` entry point to require everything and run
9. Test with `ruby -c` syntax check on all files
10. Test with `ruby chewy.rb --help` to verify it loads correctly
