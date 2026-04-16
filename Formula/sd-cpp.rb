class SdCpp < Formula
  desc "Stable Diffusion and Flux inference in pure C/C++"
  homepage "https://github.com/leejet/stable-diffusion.cpp"
  url "https://github.com/leejet/stable-diffusion.cpp/archive/refs/tags/master-569-c41c5de.tar.gz"
  version "569"
  sha256 "f3e6aaab6a3c0398a68c6dbe7247c93853dc7c54eb8f990a16e168ac8daafae4"
  license "MIT"

  resource "ggml" do
    url "https://github.com/ggml-org/ggml/archive/404fcb9d7c96989569e68c9e7881ee3465a05c50.tar.gz"
    sha256 "b6c8928df06a96bfa57a5ff570c755c21aace5c3396b123edef6481b3d44ccaa"
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
