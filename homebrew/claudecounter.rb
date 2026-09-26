# Canonical Homebrew formula for the claudecounter TUI.
#
# Source of truth: release.yml fills the __PLACEHOLDERS__ from the
# published release and writes the result to Formula/claudecounter.rb in
# jverhoeks/homebrew-tap. Edit this file, not the tap copy.
class Claudecounter < Formula
  desc "Live terminal spend tracker for Claude Code, Codex and Grok"
  homepage "https://github.com/jverhoeks/claudecounter"
  version "__VERSION__"

  on_macos do
    on_arm do
      url "https://github.com/jverhoeks/claudecounter/releases/download/v#{version}/claudecounter-darwin-arm64"
      sha256 "__SHA_DARWIN_ARM64__"
    end
    on_intel do
      url "https://github.com/jverhoeks/claudecounter/releases/download/v#{version}/claudecounter-darwin-amd64"
      sha256 "__SHA_DARWIN_AMD64__"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/jverhoeks/claudecounter/releases/download/v#{version}/claudecounter-linux-arm64"
      sha256 "__SHA_LINUX_ARM64__"
    end
    on_intel do
      url "https://github.com/jverhoeks/claudecounter/releases/download/v#{version}/claudecounter-linux-amd64"
      sha256 "__SHA_LINUX_AMD64__"
    end
  end

  def install
    bin.install Dir["claudecounter-*"].first => "claudecounter"
  end

  test do
    # No --version flag; --help lists the flags and exits 0.
    assert_match "sources-config", shell_output("#{bin}/claudecounter --help 2>&1")
  end
end
