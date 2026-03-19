# frozen_string_literal: true

# ---------- OpenAI-Compatible Provider ----------

class OpenAICompatibleProvider < Provider::Base
  def initialize(config = {})
    @base_url = config["base_url"] || "http://localhost:8080/v1"
    @display = config["name"] || "OpenAI-Compatible"
    @env_var = config["api_key_env"] || "OPENAI_COMPAT_API_KEY"
    @setup_url = config["setup_url"]
    @configured_models = (config["models"] || []).map { |m|
      { id: m["id"] || m, name: m["name"] || m["id"] || m, desc: m["desc"] || "" }
    }
  end

  def id; "openai_compat"; end
  def display_name; @display; end
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
  def api_key_env_var; @env_var; end
  def api_key_setup_url; @setup_url; end
  def api_key_set?; !!resolve_api_key; end

  def list_models
    return @configured_models unless @configured_models.empty?
    [{ id: "default", name: "Default", desc: @base_url }]
  end

  def generate(request, cancelled: -> { false }, &on_event)
    api_key = resolve_api_key
    return Provider::GenerationResult.new(error: "#{@env_var} not set") unless api_key

    on_event&.call(:status, "Sending request...")

    model = request.model || list_models.first[:id]
    n = [request.batch || 1, 1].max

    body = { model: model, prompt: request.prompt, n: n, size: "#{request.width}x#{request.height}" }
    body[:response_format] = "b64_json"

    uri = URI.parse("#{@base_url}/images/generations")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 30
    http.read_timeout = 300

    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{api_key}"
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    on_event&.call(:status, "Generating...")
    start_time = Time.now
    resp = http.request(req)
    elapsed = (Time.now - start_time).round(1)

    unless resp.is_a?(Net::HTTPSuccess)
      error_body = JSON.parse(resp.body) rescue {}
      error_msg = error_body.dig("error", "message") || "HTTP #{resp.code}: #{resp.message}"
      return Provider::GenerationResult.new(error: error_msg)
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
    Provider::GenerationResult.new(error: e.message)
  end
end
