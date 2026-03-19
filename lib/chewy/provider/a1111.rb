# frozen_string_literal: true

# ---------- A1111 (Automatic1111) Provider ----------

class A1111Provider < Provider::Base
  DEFAULT_URL = "http://127.0.0.1:7860".freeze

  def initialize(config = {})
    @base_url = config["base_url"] || DEFAULT_URL
  end

  def id; "a1111"; end
  def display_name; "A1111 (local)"; end
  def provider_type; :api; end

  def capabilities
    Provider::Capabilities.new(
      negative_prompt: true, seed: true, batch: true, img2img: true,
      live_preview: false, cancel: true, model_listing: true, lora: false,
      cfg_scale: true, sampler: true, scheduler: false, threads: false,
      strength: true, width_height: true, controlnet: false
    )
  end

  def needs_api_key?; false; end
  def api_key_set?; true; end

  def list_models
    uri = URI.parse("#{@base_url}/sdapi/v1/sd-models")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 5; http.read_timeout = 10
    resp = http.request(Net::HTTP::Get.new(uri))
    return [{ id: "default", name: "Default", desc: "Whatever is loaded in A1111" }] unless resp.is_a?(Net::HTTPSuccess)
    models = JSON.parse(resp.body)
    models.map { |m| { id: m["title"], name: m["model_name"] || m["title"], desc: m["filename"] || "" } }
  rescue
    [{ id: "default", name: "Default", desc: "Could not connect to #{@base_url}" }]
  end

  def generate(request, cancelled: -> { false }, &on_event)
    on_event&.call(:status, "Connecting to A1111...")

    endpoint = request.init_image ? "img2img" : "txt2img"
    uri = URI.parse("#{@base_url}/sdapi/v1/#{endpoint}")

    body = {
      prompt: request.prompt,
      negative_prompt: request.negative_prompt || "",
      steps: request.steps || 20,
      cfg_scale: request.cfg_scale || 7.0,
      width: request.width || 512,
      height: request.height || 512,
      seed: request.seed || -1,
      sampler_name: request.sampler || "Euler a",
      batch_size: [request.batch || 1, 1].max,
      save_images: false,
      send_images: true,
    }

    # Model override
    if request.model && request.model != "default"
      body[:override_settings] = { sd_model_checkpoint: request.model }
    end

    # img2img specific
    if request.init_image
      img_data = Base64.strict_encode64(File.binread(request.init_image))
      body[:init_images] = [img_data]
      body[:denoising_strength] = request.strength || 0.75
    end

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 30
    http.read_timeout = 600

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    on_event&.call(:status, "Generating...")
    start_time = Time.now
    resp = http.request(req)
    elapsed = (Time.now - start_time).round(1)

    unless resp.is_a?(Net::HTTPSuccess)
      error_body = JSON.parse(resp.body) rescue {}
      error_msg = error_body["detail"] || "HTTP #{resp.code}: #{resp.message}"
      return Provider::GenerationResult.new(error: error_msg)
    end

    data = JSON.parse(resp.body)
    images = data["images"] || []
    return Provider::GenerationResult.new(error: "No images returned") if images.empty?

    # Parse generation info for seeds
    info = JSON.parse(data["info"]) rescue {}
    seeds = info["all_seeds"] || [info["seed"]] || []

    on_event&.call(:status, "Saving images...")
    FileUtils.mkdir_p(request.output_dir)

    paths = []
    images.each_with_index do |b64, i|
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
      output_path = File.join(request.output_dir, "#{timestamp}_#{i}.png")
      File.binwrite(output_path, Base64.decode64(b64))
      paths << output_path
    end

    return Provider::GenerationResult.new(error: "Failed to save images") if paths.empty?
    Provider::GenerationResult.new(paths: paths, seeds: seeds, elapsed: elapsed)
  rescue Errno::ECONNREFUSED
    Provider::GenerationResult.new(error: "Cannot connect to A1111 at #{@base_url} — is it running with --api?")
  rescue => e
    Provider::GenerationResult.new(error: e.message)
  end

  def cancel(_handle)
    uri = URI.parse("#{@base_url}/sdapi/v1/interrupt")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 5; http.read_timeout = 5
    http.request(Net::HTTP::Post.new(uri))
  rescue
    nil
  end
end
