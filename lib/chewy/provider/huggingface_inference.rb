# frozen_string_literal: true

# ---------- HuggingFace Inference Provider ----------

class HuggingFaceInferenceProvider < Provider::Base
  MODELS = [
    { id: "black-forest-labs/FLUX.1-schnell", name: "FLUX.1 Schnell", desc: "Fast, 1-4 steps" },
    { id: "black-forest-labs/FLUX.1-dev", name: "FLUX.1 Dev", desc: "High quality FLUX" },
    { id: "stabilityai/stable-diffusion-xl-base-1.0", name: "SDXL 1.0", desc: "Stable Diffusion XL" },
    { id: "stabilityai/stable-diffusion-3.5-large", name: "SD 3.5 Large", desc: "Latest SD architecture" },
    { id: "HiDream-ai/HiDream-I1-Full", name: "HiDream I1", desc: "High detail generation" },
  ].freeze

  BASE_URL = "https://router.huggingface.co/hf-inference/models".freeze

  def id; "huggingface"; end
  def display_name; "HuggingFace"; end
  def provider_type; :api; end

  def capabilities
    Provider::Capabilities.new(
      negative_prompt: true, seed: true, batch: false, img2img: false,
      live_preview: false, cancel: false, model_listing: true, lora: false,
      cfg_scale: true, sampler: false, scheduler: false, threads: false,
      strength: false, width_height: true
    )
  end

  def needs_api_key?; true; end
  def api_key_env_var; "HF_TOKEN"; end
  def api_key_setup_url; "huggingface.co/settings/tokens"; end
  def api_key_set?; !!resolve_api_key; end

  def resolve_api_key
    # Check env vars and standard HF token paths
    ENV["HF_TOKEN"] || ENV["HUGGING_FACE_HUB_TOKEN"] ||
      [File.expand_path("~/.cache/huggingface/token"),
       File.expand_path("~/.huggingface/token")].filter_map { |p|
        File.read(p).strip if File.exist?(p)
      }.first || load_stored_key
  end

  def store_api_key(key)
    # Store in standard HF location so it works for companion downloads too
    dir = File.expand_path("~/.cache/huggingface")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "token")
    File.write(path, key)
    File.chmod(0600, path)
  rescue
    super(key)  # fall back to keys dir
  end

  def list_models; MODELS; end

  def generate(request, cancelled: -> { false }, &on_event)
    api_key = resolve_api_key
    return Provider::GenerationResult.new(error: "HF_TOKEN not set") unless api_key

    model_id = request.model || MODELS.first[:id]
    on_event&.call(:status, "Sending request to HuggingFace...")

    body = { inputs: request.prompt }
    params = {}
    neg = request.negative_prompt.to_s.strip
    params[:negative_prompt] = neg unless neg.empty?
    params[:guidance_scale] = request.cfg_scale if request.cfg_scale
    params[:num_inference_steps] = request.steps if request.steps
    params[:width] = request.width if request.width
    params[:height] = request.height if request.height
    params[:seed] = request.seed if request.seed && request.seed >= 0
    body[:parameters] = params unless params.empty?

    uri = URI.parse("#{BASE_URL}/#{model_id}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 30
    http.read_timeout = 300

    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{api_key}"
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    model_name = MODELS.find { |m| m[:id] == model_id }&.dig(:name) || model_id.split("/").last
    on_event&.call(:status, "Generating with #{model_name}...")

    start_time = Time.now
    resp = http.request(req)
    elapsed = (Time.now - start_time).round(1)

    unless resp.is_a?(Net::HTTPSuccess)
      error_body = JSON.parse(resp.body) rescue {}
      error_msg = error_body["error"] || "HTTP #{resp.code}: #{resp.message}"
      if resp.code == "401"
        error_msg = "Token invalid or missing inference permission — create a new token at huggingface.co/settings/tokens with 'Make calls to Inference Providers' enabled"
      elsif resp.code == "503"
        error_msg = "Model is loading, try again in a moment"
      end
      return Provider::GenerationResult.new(error: "HuggingFace: #{error_msg}")
    end

    on_event&.call(:status, "Saving image...")
    FileUtils.mkdir_p(request.output_dir)

    content_type = resp["content-type"].to_s
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
    output_path = File.join(request.output_dir, "#{timestamp}_0.png")

    if content_type.include?("image/")
      # Binary image response (standard for inference API)
      File.binwrite(output_path, resp.body)
    else
      # JSON response (might have base64)
      data = JSON.parse(resp.body) rescue nil
      if data.is_a?(Array) && data.first&.dig("blob")
        File.binwrite(output_path, Base64.decode64(data.first["blob"]))
      elsif data.is_a?(Hash) && data["b64_json"]
        File.binwrite(output_path, Base64.decode64(data["b64_json"]))
      else
        return Provider::GenerationResult.new(error: "Unexpected response format")
      end
    end

    seed_val = request.seed && request.seed >= 0 ? request.seed : nil
    Provider::GenerationResult.new(paths: [output_path], seeds: [seed_val], elapsed: elapsed)
  rescue => e
    Provider::GenerationResult.new(error: "HuggingFace: #{e.message}")
  end
end
