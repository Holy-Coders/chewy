# frozen_string_literal: true

# ---------- Gemini Provider ----------

class GeminiProvider < Provider::Base
  MODELS = [
    { id: "imagen-3.0-generate-002", name: "Imagen 3", desc: "Google's best image model" },
    { id: "imagen-3.0-fast-generate-001", name: "Imagen 3 Fast", desc: "Faster, lower cost" },
    { id: "gemini-2.0-flash-exp", name: "Gemini 2.0 Flash", desc: "Native Gemini image gen" },
  ].freeze

  def id; "gemini"; end
  def display_name; "Gemini"; end
  def provider_type; :api; end

  def capabilities
    Provider::Capabilities.new(
      negative_prompt: true, seed: false, batch: true, img2img: false,
      live_preview: false, cancel: false, model_listing: true, lora: false,
      cfg_scale: false, sampler: false, scheduler: false, threads: false,
      strength: false, width_height: true
    )
  end

  def needs_api_key?; true; end
  def api_key_env_var; "GEMINI_API_KEY"; end
  def api_key_setup_url; "aistudio.google.com/apikey"; end
  def api_key_set?; !!resolve_api_key; end

  def list_models; MODELS; end

  def generate(request, cancelled: -> { false }, &on_event)
    api_key = resolve_api_key
    return Provider::GenerationResult.new(error: "GEMINI_API_KEY not set") unless api_key

    model_id = request.model || MODELS.first[:id]
    on_event&.call(:status, "Sending request to Gemini...")

    is_imagen = model_id.start_with?("imagen")
    n = [request.batch || 1, 1].max

    if is_imagen
      result = generate_imagen(api_key, model_id, request, n, on_event)
    else
      result = generate_gemini_native(api_key, model_id, request, on_event)
    end
    result
  rescue => e
    Provider::GenerationResult.new(error: "Gemini: #{e.message}")
  end

  private

  def generate_imagen(api_key, model_id, request, n, on_event)
    uri = URI.parse("https://generativelanguage.googleapis.com/v1beta/models/#{model_id}:predict?key=#{api_key}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 30
    http.read_timeout = 300

    body = {
      instances: [{ prompt: request.prompt }],
      parameters: {
        sampleCount: [n, 4].min,
        aspectRatio: nearest_aspect(request.width, request.height),
      },
    }
    neg = request.negative_prompt.to_s.strip
    body[:parameters][:negativePrompt] = neg unless neg.empty?

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    model_name = MODELS.find { |m| m[:id] == model_id }&.dig(:name) || model_id
    on_event&.call(:status, "Generating with #{model_name}...")

    start_time = Time.now
    resp = http.request(req)
    elapsed = (Time.now - start_time).round(1)

    unless resp.is_a?(Net::HTTPSuccess)
      error_body = JSON.parse(resp.body) rescue {}
      error_msg = error_body.dig("error", "message") || "HTTP #{resp.code}: #{resp.message}"
      return Provider::GenerationResult.new(error: "Gemini: #{error_msg}")
    end

    data = JSON.parse(resp.body)
    predictions = data["predictions"] || []
    return Provider::GenerationResult.new(error: "No images returned") if predictions.empty?

    on_event&.call(:status, "Saving images...")
    FileUtils.mkdir_p(request.output_dir)

    paths = []
    predictions.each_with_index do |pred, i|
      b64 = pred["bytesBase64Encoded"]
      next unless b64
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
      output_path = File.join(request.output_dir, "#{timestamp}_#{i}.png")
      File.binwrite(output_path, Base64.decode64(b64))
      paths << output_path
    end

    return Provider::GenerationResult.new(error: "Failed to save images") if paths.empty?
    Provider::GenerationResult.new(paths: paths, seeds: [nil] * paths.length, elapsed: elapsed)
  end

  def generate_gemini_native(api_key, model_id, request, on_event)
    uri = URI.parse("https://generativelanguage.googleapis.com/v1beta/models/#{model_id}:generateContent?key=#{api_key}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 30
    http.read_timeout = 300

    body = {
      contents: [{ parts: [{ text: request.prompt }] }],
      generationConfig: { responseModalities: ["TEXT", "IMAGE"] },
    }

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    model_name = MODELS.find { |m| m[:id] == model_id }&.dig(:name) || model_id
    on_event&.call(:status, "Generating with #{model_name}...")

    start_time = Time.now
    resp = http.request(req)
    elapsed = (Time.now - start_time).round(1)

    unless resp.is_a?(Net::HTTPSuccess)
      error_body = JSON.parse(resp.body) rescue {}
      error_msg = error_body.dig("error", "message") || "HTTP #{resp.code}: #{resp.message}"
      return Provider::GenerationResult.new(error: "Gemini: #{error_msg}")
    end

    data = JSON.parse(resp.body)
    parts = data.dig("candidates", 0, "content", "parts") || []
    image_parts = parts.select { |p| p.dig("inlineData", "mimeType")&.start_with?("image/") }
    return Provider::GenerationResult.new(error: "No images in response") if image_parts.empty?

    on_event&.call(:status, "Saving images...")
    FileUtils.mkdir_p(request.output_dir)

    paths = []
    image_parts.each_with_index do |part, i|
      b64 = part.dig("inlineData", "data")
      next unless b64
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
      output_path = File.join(request.output_dir, "#{timestamp}_#{i}.png")
      File.binwrite(output_path, Base64.decode64(b64))
      paths << output_path
    end

    return Provider::GenerationResult.new(error: "Failed to save images") if paths.empty?
    Provider::GenerationResult.new(paths: paths, seeds: [nil] * paths.length, elapsed: elapsed)
  end

  def nearest_aspect(w, h)
    aspect = w.to_f / h
    aspects = { "1:1" => 1.0, "3:4" => 0.75, "4:3" => 1.333, "9:16" => 0.5625, "16:9" => 1.778 }
    aspects.min_by { |_, v| (aspect - v).abs }.first
  end
end
