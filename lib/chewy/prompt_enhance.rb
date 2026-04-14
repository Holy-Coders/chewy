# frozen_string_literal: true

class Chewy
  module PromptEnhance
    ENHANCE_SYSTEM = <<~PROMPT.freeze
      You are an expert at writing prompts for Stable Diffusion and FLUX image generation models.
      The user will give you a rough prompt. Expand it into a detailed, effective image generation prompt.
      Rules:
      - Output ONLY the enhanced prompt text. No explanations, no quotes, no prefixes.
      - Keep the user's core subject and intent.
      - Add details: lighting, composition, camera angle, atmosphere, color palette.
      - Add quality boosters: highly detailed, sharp focus, professional, etc.
      - Under 200 words. Comma-separated descriptors, not full sentences.
      - Do NOT include negative prompt content.
    PROMPT

    NEGATIVE_SYSTEM = <<~PROMPT.freeze
      You are an expert at writing negative prompts for Stable Diffusion image generation.
      The user will give you their positive prompt. Generate a negative prompt.
      Rules:
      - Output ONLY the negative prompt text. No explanations, no quotes.
      - Include: blurry, low quality, deformed, bad anatomy, watermark, text, signature.
      - Tailor to the subject. Under 50 words. Comma-separated terms.
    PROMPT

    RANDOM_SYSTEM = <<~PROMPT.freeze
      You are a creative prompt generator for AI image generation.
      Generate a single creative, detailed image prompt.
      Rules:
      - Output ONLY the prompt text. No explanations, no quotes.
      - Pick a random subject: portrait, landscape, fantasy, sci-fi, still life, architectural, abstract.
      - Include: subject, setting, lighting, style, mood, composition.
      - Under 150 words. Comma-separated descriptors. Be creative and surprising.
    PROMPT

    OLLAMA_MODEL = "llama3.2:3b"
    OLLAMA_PORTS = [11434, 1234, 8080].freeze
    LOCAL_NEGATIVE = "blurry, low quality, worst quality, deformed, ugly, bad anatomy, disfigured, watermark, text, signature, cropped, out of frame, duplicate, noise, jpeg artifacts"

    RANDOM_PROMPTS = [
      "a weathered lighthouse on a rocky cliff at sunset, dramatic storm clouds, golden hour lighting, oil painting style, moody atmosphere, highly detailed, crashing waves",
      "close-up portrait of an elderly craftsman in his workshop, warm amber lighting, shallow depth of field, sawdust particles in air, photorealistic, 8k uhd",
      "futuristic cyberpunk street market at night, neon signs reflecting in puddles, rain, crowded with diverse characters, cinematic composition, blade runner aesthetic",
      "tiny fairy village inside a hollow tree trunk, bioluminescent mushrooms, fireflies, magical atmosphere, macro photography style, tilt-shift effect, enchanted forest",
      "abandoned Art Deco theater overgrown with vines and flowers, sunbeams through broken ceiling, birds nesting in chandeliers, post-apocalyptic beauty, highly detailed",
      "underwater coral reef at golden hour, light rays penetrating clear water, sea turtle swimming, tropical fish, vibrant colors, national geographic style photography",
      "steampunk inventor's laboratory, brass instruments, bubbling beakers, clockwork mechanisms, warm gaslight, leather-bound books, detailed victorian interior, atmospheric",
      "snow-covered Japanese temple garden at dawn, zen rock garden, cherry blossom trees with snow, misty mountains background, serene, minimalist composition, ukiyo-e inspired",
      "massive ancient tree in a bioluminescent forest, glowing roots, fantasy landscape, ethereal atmosphere, concept art style, volumetric lighting, magical realism",
      "street photographer capturing rain in Tokyo, reflections on wet pavement, umbrellas, city lights bokeh, black and white with selective color, cinematic mood",
    ].freeze

    private

    def resolve_prompt_llm
      # 1. Check for local ollama/LM Studio/llama.cpp server
      OLLAMA_PORTS.each do |port|
        begin
          uri = URI.parse("http://localhost:#{port}/v1/models")
          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = 1; http.read_timeout = 2
          resp = http.request(Net::HTTP::Get.new(uri))
          if resp.is_a?(Net::HTTPSuccess)
            return { provider: :local_llm, base_url: "http://localhost:#{port}", api_key: nil }
          end
        rescue
          next
        end
      end

      # 2. Check OpenAI
      openai_key = ENV["OPENAI_API_KEY"] || load_provider_key("openai")
      return { provider: :openai, api_key: openai_key } if openai_key

      # 3. Check Gemini
      gemini_key = ENV["GEMINI_API_KEY"] || load_provider_key("gemini")
      return { provider: :gemini, api_key: gemini_key } if gemini_key

      # 4. Local fallback
      { provider: :local_rules }
    end

    def load_provider_key(id)
      path = File.join(Provider::KEYS_DIR, "#{id}.key")
      return nil unless File.exist?(path)
      key = File.read(path).strip
      key.empty? ? nil : key
    rescue
      nil
    end

    def ollama_installed?
      system("which ollama > /dev/null 2>&1")
    end

    def ollama_has_model?(model)
      output = `ollama list 2>/dev/null`
      output.include?(model.split(":").first)
    rescue
      false
    end

    def enhance_prompt
      text = @prompt_input.value.strip
      return [self, set_error_toast("Type a prompt first")] if text.empty?
      return [self, nil] if @prompt_enhancing

      @prompt_enhancing = true
      is_flux = @provider.provider_type == :local && @selected_model_path && flux_model?(@selected_model_path)
      llm = resolve_prompt_llm

      cmd = Proc.new do
        result = case llm[:provider]
        when :local_llm
          user_msg = is_flux ? "Enhance for FLUX model (use natural language, not tags): #{text}" : "Enhance for Stable Diffusion: #{text}"
          call_local_llm(llm[:base_url], ENHANCE_SYSTEM, user_msg)
        when :openai
          user_msg = is_flux ? "Enhance for FLUX model: #{text}" : "Enhance for Stable Diffusion: #{text}"
          r = call_openai_chat(llm[:api_key], ENHANCE_SYSTEM, user_msg)
          detect_refusal!(r, "OpenAI"); r
        when :gemini
          user_msg = is_flux ? "Enhance for FLUX model: #{text}" : "Enhance for Stable Diffusion: #{text}"
          r = call_gemini_chat(llm[:api_key], ENHANCE_SYSTEM, user_msg)
          detect_refusal!(r, "Gemini"); r
        else
          enhance_prompt_local(text, is_flux)
        end
        PromptEnhanceMessage.new(text: clean_llm_response(result), target: :prompt)
      rescue => e
        PromptEnhanceMessage.new(target: :prompt, error: e.message)
      end

      [self, cmd]
    end

    def generate_negative_prompt
      text = @prompt_input.value.strip
      return [self, set_error_toast("Type a prompt first")] if text.empty?
      return [self, nil] if @prompt_enhancing

      @prompt_enhancing = true
      llm = resolve_prompt_llm

      cmd = Proc.new do
        result = case llm[:provider]
        when :local_llm
          call_local_llm(llm[:base_url], NEGATIVE_SYSTEM, text)
        when :openai
          r = call_openai_chat(llm[:api_key], NEGATIVE_SYSTEM, text)
          detect_refusal!(r, "OpenAI"); r
        when :gemini
          r = call_gemini_chat(llm[:api_key], NEGATIVE_SYSTEM, text)
          detect_refusal!(r, "Gemini"); r
        else
          LOCAL_NEGATIVE
        end
        PromptEnhanceMessage.new(text: clean_llm_response(result), target: :negative)
      rescue => e
        PromptEnhanceMessage.new(target: :negative, error: e.message)
      end

      [self, cmd]
    end

    def generate_random_prompt
      return [self, nil] if @prompt_enhancing

      @prompt_enhancing = true
      llm = resolve_prompt_llm

      cmd = Proc.new do
        result = case llm[:provider]
        when :local_llm
          call_local_llm(llm[:base_url], RANDOM_SYSTEM, "Generate a creative image prompt")
        when :openai
          call_openai_chat(llm[:api_key], RANDOM_SYSTEM, "Generate a creative image prompt")
        when :gemini
          call_gemini_chat(llm[:api_key], RANDOM_SYSTEM, "Generate a creative image prompt")
        else
          RANDOM_PROMPTS.sample
        end
        PromptEnhanceMessage.new(text: clean_llm_response(result), target: :random)
      rescue => e
        PromptEnhanceMessage.new(target: :random, error: e.message)
      end

      [self, cmd]
    end

    def setup_ollama
      return [self, nil] if @prompt_enhancing

      unless ollama_installed?
        return [self, set_error_toast("Install ollama first: brew install ollama")]
      end

      @prompt_enhancing = true
      @status_message = "Setting up ollama (downloading #{OLLAMA_MODEL})..."

      cmd = Proc.new do
        # Start ollama serve if not running
        unless OLLAMA_PORTS.any? { |p| begin; Net::HTTP.get_response(URI("http://localhost:#{p}/v1/models")); true; rescue; false; end }
          spawn("ollama", "serve", [:out, :err] => "/dev/null")
          sleep 2
        end
        # Pull model if needed
        unless ollama_has_model?(OLLAMA_MODEL)
          system("ollama", "pull", OLLAMA_MODEL)
        end
        PromptEnhanceMessage.new(text: nil, target: :setup)
      rescue => e
        PromptEnhanceMessage.new(target: :setup, error: e.message)
      end

      [self, cmd]
    end

    def handle_prompt_enhance_result(message)
      @prompt_enhancing = false
      if message.target == :setup
        if message.error
          [self, set_error_toast("Ollama setup failed: #{message.error}")]
        else
          [self, set_status_toast("Ollama ready with #{OLLAMA_MODEL}")]
        end
      elsif message.error
        [self, set_error_toast(message.error)]
      else
        case message.target
        when :prompt, :random
          @prompt_input.value = message.text
          @prompt_input.cursor_end
          [self, set_status_toast(message.target == :random ? "Random prompt generated" : "Prompt enhanced")]
        when :negative
          @negative_input.value = message.text
          @negative_input.cursor_end
          [self, set_status_toast("Negative prompt generated")]
        end
      end
    end

    def call_local_llm(base_url, system_prompt, user_prompt)
      uri = URI.parse("#{base_url}/v1/chat/completions")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 5; http.read_timeout = 60

      # Get first available model
      models_uri = URI.parse("#{base_url}/v1/models")
      models_resp = http.request(Net::HTTP::Get.new(models_uri))
      models_data = JSON.parse(models_resp.body)
      model_id = models_data.dig("data", 0, "id") || OLLAMA_MODEL

      body = {
        model: model_id,
        messages: [
          { role: "system", content: system_prompt },
          { role: "user", content: user_prompt },
        ],
        max_tokens: 500,
        temperature: 0.8,
        stream: false,
      }

      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)

      resp = http.request(req)
      raise "Local LLM: HTTP #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)

      data = JSON.parse(resp.body)
      data.dig("choices", 0, "message", "content")&.strip || raise("Empty response from LLM")
    end

    def call_openai_chat(api_key, system_prompt, user_prompt)
      uri = URI.parse("https://api.openai.com/v1/chat/completions")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 15; http.read_timeout = 30

      body = {
        model: "gpt-4o-mini",
        messages: [
          { role: "system", content: system_prompt },
          { role: "user", content: user_prompt },
        ],
        max_tokens: 500,
        temperature: 0.8,
      }

      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{api_key}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)

      resp = http.request(req)
      raise "OpenAI: #{JSON.parse(resp.body).dig('error', 'message') || resp.code}" unless resp.is_a?(Net::HTTPSuccess)

      data = JSON.parse(resp.body)
      data.dig("choices", 0, "message", "content")&.strip || raise("Empty response")
    end

    def call_gemini_chat(api_key, system_prompt, user_prompt)
      uri = URI.parse("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=#{api_key}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 15; http.read_timeout = 30

      body = {
        system_instruction: { parts: [{ text: system_prompt }] },
        contents: [{ parts: [{ text: user_prompt }] }],
        generationConfig: { maxOutputTokens: 500, temperature: 0.8 },
        # Disable Gemini's default safety filters so NSFW prompts aren't blocked.
        # OpenAI has no equivalent knob — NSFW must be done via local LLM or Gemini.
        safetySettings: [
          { category: "HARM_CATEGORY_HARASSMENT",        threshold: "BLOCK_NONE" },
          { category: "HARM_CATEGORY_HATE_SPEECH",       threshold: "BLOCK_NONE" },
          { category: "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold: "BLOCK_NONE" },
          { category: "HARM_CATEGORY_DANGEROUS_CONTENT", threshold: "BLOCK_NONE" },
        ],
      }

      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)

      resp = http.request(req)
      raise "Gemini: #{JSON.parse(resp.body).dig('error', 'message') || resp.code}" unless resp.is_a?(Net::HTTPSuccess)

      data = JSON.parse(resp.body)
      # Gemini may return a successful HTTP response but block the content —
      # surface that as a clear refusal rather than a generic "Empty response".
      if (block = data.dig("promptFeedback", "blockReason"))
        raise "Gemini blocked the prompt (#{block}) — switch to a local LLM (ollama) to bypass hosted filters."
      end
      finish = data.dig("candidates", 0, "finishReason")
      if finish && %w[SAFETY PROHIBITED_CONTENT BLOCKLIST].include?(finish)
        raise "Gemini refused the prompt (#{finish}) — switch to a local LLM (ollama) to bypass hosted filters."
      end
      data.dig("candidates", 0, "content", "parts", 0, "text")&.strip || raise("Empty response")
    end

    def enhance_prompt_local(text, is_flux)
      if is_flux
        "#{text}, highly detailed, professional photography, perfect composition, dramatic lighting, sharp focus, 8k resolution"
      else
        "#{text}, highly detailed, sharp focus, professional, masterpiece, best quality, 8k uhd, studio lighting, vibrant colors"
      end
    end

    def clean_llm_response(text)
      return text unless text
      # Strip common LLM wrapper artifacts
      text = text.strip
      text = text.gsub(/\A["']|["']\z/, '')  # leading/trailing quotes
      text = text.sub(/\A(Here('s| is) (the |your )?(enhanced |improved |negative )?prompt:?\s*)/i, '')
      text = text.sub(/\A(Prompt:?\s*)/i, '')
      text.strip
    end

    # Hosted LLMs (OpenAI, Gemini) refuse NSFW prompts with refusal prose rather
    # than an API error. If the "enhanced" text looks like a refusal, raise so
    # we show an error toast instead of pasting the refusal into the prompt box.
    REFUSAL_PATTERNS = [
      /\AI (can't|cannot|won't|will not|am unable|am not able) /i,
      /\AI'm (sorry|unable|not able|afraid) /i,
      /\A(Sorry|Unfortunately),?\s+I /i,
      /\b(violat|against|comply with).{0,30}(policy|policies|guideline|content)\b/i,
      /\b(cannot|can't)\s+(generate|create|help|assist|produce|write).{0,40}(explicit|sexual|nsfw|adult|inappropriate)\b/i,
    ].freeze

    def detect_refusal!(text, provider_label)
      return unless text
      snippet = text.strip[0, 400]
      return unless REFUSAL_PATTERNS.any? { |re| snippet =~ re }
      raise "#{provider_label} refused the prompt (content policy). Set up a local LLM — e.g. ollama — to bypass hosted filters."
    end
  end
end
