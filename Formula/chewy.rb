class Chewy < Formula
  desc "TUI for local AI image generation with Stable Diffusion and FLUX"
  homepage "https://github.com/Holy-Coders/chewy"
  url "https://github.com/Holy-Coders/chewy/archive/refs/tags/v0.1.0.tar.gz"
  version "0.1.0"
  sha256 "PLACEHOLDER"
  license "MIT"

  depends_on "holy-coders/chewy/sd-cpp"
  depends_on "ruby"

  def install
    ENV["GEM_HOME"] = libexec/"gems"
    ENV["GEM_PATH"] = libexec/"gems"

    system "gem", "install", "bundler", "--no-document", "--install-dir", libexec/"gems"

    bundle = libexec/"gems/bin/bundle"
    system bundle, "config", "set", "--local", "path", libexec/"gems"
    system bundle, "config", "set", "--local", "without", "development:test"
    system bundle, "install"

    libexec.install "chewy.rb"
    libexec.install "Gemfile"
    libexec.install "Gemfile.lock"
    libexec.install "logo.jpeg"
    libexec.install "VERSION"

    (bin/"chewy").write <<~BASH
      #!/bin/bash
      export GEM_HOME="#{libexec}/gems"
      export GEM_PATH="#{libexec}/gems"
      exec "#{Formula["ruby"].opt_bin}/ruby" "#{libexec}/chewy.rb" "$@"
    BASH
  end

  def caveats
    <<~EOS

            ▄▄████▄▄
          ▄██▀▄██▄▀██▄
         ██▀▄█▀▀▀█▄▀██
        ██ ▄▀ ▄▄▄ ▀▄ ██
        ██ █ █▀ ▀█ █ ██
        ██ ▀▄ ▀▄▀ ▄▀ ██
         ██▄▀▀▄▄▄▀▀▄██
          ▀██▄▄▄▄▄██▀
            ▀▀████▀▀

      Run `chewy` to launch the TUI.

      Place models in ~/models or set CHEWY_MODELS_DIR.
      Press ^d inside chewy to download models from HuggingFace.
    EOS
  end

  test do
    assert_predicate bin/"chewy", :executable?
  end
end
