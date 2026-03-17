class SdCpp < Formula
  desc "Stable Diffusion and Flux inference in pure C/C++"
  homepage "https://github.com/leejet/stable-diffusion.cpp"
  url "https://github.com/leejet/stable-diffusion.cpp/archive/refs/tags/master-537-545fac4.tar.gz"
  version "537"
  sha256 "475307d14bda550742729a422aafc7b3cb10f8c3f57957b2d1470f0e967313c9"
  license "MIT"

  resource "ggml" do
    url "https://github.com/ggml-org/ggml/archive/a8db410a252c8c8f2d120c6f2e7133ebe032f35d.tar.gz"
    sha256 "3f6acec7660e784325214c2d53d45035c426d28b8763266f0ef3cdc9f9f1d103"
  end

  depends_on "cmake" => :build

  def install
    resource("ggml").stage(buildpath/"ggml")

    args = %w[
      -DSD_BUILD_EXAMPLES=ON
      -DGGML_CCACHE=OFF
    ]

    # Enable Metal GPU acceleration on macOS
    args << "-DSD_METAL=ON" if OS.mac?

    system "cmake", "-S", ".", "-B", "build", *args, *std_cmake_args
    system "cmake", "--build", "build", "--config", "Release"
    bin.install "build/bin/sd-cli" => "sd"
  end

  test do
    assert_match "stable-diffusion.cpp", shell_output("#{bin}/sd --version 2>&1", 1)
  end
end
