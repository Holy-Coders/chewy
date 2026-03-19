# frozen_string_literal: true

# ---------- OpenAI Images Provider ----------

class OpenAIImagesProvider < Provider::Base
  MODELS = [
    { id: "gpt-image-1", name: "GPT Image 1", desc: "Latest OpenAI image model" },
    { id: "dall-e-3", name: "DALL-E 3", desc: "High quality, creative" },
    { id: "dall-e-2", name: "DALL-E 2", desc: "Fast, lower cost" },
  ].freeze

  SIZES = {
    "gpt-image-1" => %w[1024x1024 1024x1536 1536x1024 auto],
    "dall-e-3"    => %w[1024x1024 1024x1792 1792x1024],
    "dall-e-2"    => %w[256x256 512x512 1024x1024],
  }.freeze

  def id; "openai"; end
  def display_name; "OpenAI"; end
  def provider_type; :api; end

  def capabilities
    Provider::Capabilities.new(
      negative_prompt: false, seed: false, batch: true, img2img: false,
      live_preview: false, cancel: false, model_listing: true, lora: false,
      cfg_scale: false, sampler: false, scheduler: false, threads: false,
      strength: false, width_height: true
    )
  end

  def needs_api_key?; true; end
  def api_key_env_var; "OPENAI_API_KEY"; end
  def api_key_setup_url; "platform.openai.com/api-keys"; end
  def api_key_set?; !!resolve_api_key; end

  def list_models; MODELS; end

  def generate(request, cancelled: -> { false }, &on_event)
    api_key = resolve_api_key
    return Provider::GenerationResult.new(error: "OPENAI_API_KEY not set") unless api_key

    on_event&.call(:status, "Sending request to OpenAI...")

    model = request.model || "gpt-image-1"
    size = nearest_size(model, request.width, request.height)
    n = [request.batch || 1, 1].max

    # Normalize model — may come from another provider's selection
    model = "gpt-image-1" unless MODELS.any? { |m| m[:id] == model }

    body = { model: model, prompt: request.prompt, n: n, size: size }

    case model
    when "gpt-image-1"
      body[:quality] = request.steps && request.steps >= 20 ? "high" : "auto"
      body[:output_format] = "png"
    when "dall-e-3"
      body[:quality] = request.steps && request.steps >= 20 ? "hd" : "standard"
      body[:response_format] = "b64_json"
      body[:n] = 1  # dall-e-3 only supports n=1
    when "dall-e-2"
      body[:response_format] = "b64_json"
    end

    uri = URI.parse("https://api.openai.com/v1/images/generations")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 30
    http.read_timeout = 300

    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{api_key}"
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    on_event&.call(:status, "Generating with #{model}...")
    start_time = Time.now
    resp = http.request(req)
    elapsed = (Time.now - start_time).round(1)

    unless resp.is_a?(Net::HTTPSuccess)
      error_body = JSON.parse(resp.body) rescue {}
      error_msg = error_body.dig("error", "message") || "HTTP #{resp.code}: #{resp.message}"
      return Provider::GenerationResult.new(error: "OpenAI: #{error_msg}")
    end

    data = JSON.parse(resp.body)
    images = data["data"] || []
    return Provider::GenerationResult.new(error: "No images returned") if images.empty?

    on_event&.call(:status, "Saving images...")
    FileUtils.mkdir_p(request.output_dir)

    paths = []
    images.each_with_index do |img, i|
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
      output_path = File.join(request.output_dir, "#{timestamp}_#{i}.png")

      if img["b64_json"]
        File.binwrite(output_path, Base64.decode64(img["b64_json"]))
        paths << output_path
      elsif img["url"]
        img_uri = URI.parse(img["url"])
        img_http = Net::HTTP.new(img_uri.host, img_uri.port)
        img_http.use_ssl = (img_uri.scheme == "https")
        img_resp = img_http.request(Net::HTTP::Get.new(img_uri))
        if img_resp.is_a?(Net::HTTPSuccess)
          File.binwrite(output_path, img_resp.body)
          paths << output_path
        end
      end
    end

    return Provider::GenerationResult.new(error: "Failed to save images") if paths.empty?

    Provider::GenerationResult.new(paths: paths, seeds: [nil] * paths.length, elapsed: elapsed)
  rescue => e
    Provider::GenerationResult.new(error: "OpenAI: #{e.message}")
  end

  private

  def nearest_size(model, w, h)
    valid = SIZES[model] || SIZES["gpt-image-1"]
    concrete = valid.reject { |s| s == "auto" }
    return valid.first if concrete.empty?

    aspect = w.to_f / h
    concrete.min_by do |s|
      sw, sh = s.split("x").map(&:to_i)
      (aspect - sw.to_f / sh).abs
    end
  end
end
