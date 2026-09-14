# Homebrew formula. Copy into davehortonairiacom/homebrew-tap as
# Formula/switcher.rb, then: brew tap davehortonairiacom/tap && brew install switcher
#
# `make release` fills in the url and sha256 for a tagged version.
class Switcher < Formula
  desc "Menu bar switch for Claude Code inference routing (Airia gateway or direct)"
  homepage "https://github.com/davehortonairiacom/Switcher"
  url "https://github.com/davehortonairiacom/Switcher/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "FILL_IN_AFTER_TAGGING"
  license "MIT"
  head "https://github.com/davehortonairiacom/Switcher.git", branch: "main"

  depends_on macos: :sonoma # MenuBarExtra + SMAppService need macOS 14+

  def install
    # Native-only: Homebrew builds per-machine, so the x86_64 slice is wasted work.
    # --disable-sandbox because SwiftPM's build database dislikes Homebrew's sandbox.
    system "make", "app",
           "UNIVERSAL=0",
           "SWIFT_EXTRA=--disable-sandbox",
           "BUILD_DIR=#{buildpath}/.build"

    prefix.install "dist/Switcher.app"
    bin.install "dist/bin/switcher"
  end

  def caveats
    <<~EOS
      Switcher is a menu bar app. Link it into your Applications folder and launch it:

        ln -sfn #{opt_prefix}/Switcher.app ~/Applications/Switcher.app
        open ~/Applications/Switcher.app

      Then tick "Start at login" in the panel.

      The CLI is on your PATH as `switcher` (try: switcher status).

      Switcher starts in Unmanaged mode and changes nothing until you pick a route.
    EOS
  end

  test do
    # Hermetic: point it at a scratch directory rather than the real ~/.claude.
    ENV["SWITCHER_CLAUDE_DIR"] = testpath
    assert_match "DIRECT", shell_output("#{bin}/switcher status")
  end
end
