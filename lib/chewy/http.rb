# frozen_string_literal: true

module Chewy::Http
  private

  def hf_get(uri, limit = 5)
    raise "Too many redirects" if limit == 0
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.read_timeout = 30; http.open_timeout = 10
    req = Net::HTTP::Get.new(uri)
    req["Accept"] = "application/json"; req["User-Agent"] = "chewy-tui/1.0"
    resp = http.request(req)
    case resp
    when Net::HTTPRedirection then hf_get(URI.parse(resp["location"]), limit - 1)
    when Net::HTTPSuccess then resp
    else raise "HTTP #{resp.code}: #{resp.message}"
    end
  end

  def surface_bg_escape
    hex = Theme.SURFACE.sub("#", "")
    r = hex[0, 2].to_i(16)
    g = hex[2, 2].to_i(16)
    b = hex[4, 2].to_i(16)
    "\e[48;2;#{r};#{g};#{b}m"
  end

  def clear_corner_backgrounds(str)
    lines = str.split("\n")
    return str if lines.length < 2

    lines[0] = lines[0]
      .sub(/(\e\[[\d;]*m)*(\e\[48;2;[\d;]+m)(\e\[[\d;]*m)*(\u256D)/) { "#{$1}\e[49m#{$3}#{$4}" }
      .sub(/(\e\[[\d;]*m)*(\e\[48;2;[\d;]+m)(\e\[[\d;]*m)*(\u256E)/) { "#{$1}\e[49m#{$3}#{$4}" }

    lines[-1] = lines[-1]
      .sub(/(\e\[[\d;]*m)*(\e\[48;2;[\d;]+m)(\e\[[\d;]*m)*(\u2570)/) { "#{$1}\e[49m#{$3}#{$4}" }
      .sub(/(\e\[[\d;]*m)*(\e\[48;2;[\d;]+m)(\e\[[\d;]*m)*(\u256F)/) { "#{$1}\e[49m#{$3}#{$4}" }

    lines.join("\n")
  end

  def format_bytes(bytes)
    if bytes >= 1_073_741_824 then "%.1f GB" % (bytes.to_f / 1_073_741_824)
    elsif bytes >= 1_048_576 then "%.1f MB" % (bytes.to_f / 1_048_576)
    elsif bytes >= 1024 then "%.1f KB" % (bytes.to_f / 1024)
    else "#{bytes} B"
    end
  end

  def format_number(n)
    n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end
end
