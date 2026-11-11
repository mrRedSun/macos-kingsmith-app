# Builds the app from source, so macOS runs it without Apple notarization.
class Walkingpad < Formula
  desc "Menu-bar client for KingSmith WalkingPad treadmills"
  homepage "https://github.com/mrRedSun/macos-kingsmith-app"
  url "https://github.com/mrRedSun/macos-kingsmith-app/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "dfc5d3596cca94618846e9ba5d1e9e004dd43d20ef1a8b74c462eb206838e1bf"
  license "MIT"
  head "https://github.com/mrRedSun/macos-kingsmith-app.git", branch: "main"

  depends_on macos: :tahoe

  def install
    system "swift", "build", "--disable-sandbox", "--configuration", "release", "--product", "WalkingPad"
    app = prefix/"WalkingPad.app"
    (app/"Contents/MacOS").install ".build/release/WalkingPad"
    (app/"Contents").install "Resources/Info.plist"
    (app/"Contents/Resources").install "THIRD_PARTY_NOTICES.md", "Resources/Icon/Assets.car", "Resources/Icon/AppIcon.icns"
    system "codesign", "--force", "--sign", "-", "--identifier", "app.walkingpad.native", app
  end

  def caveats
    <<~EOS
      Add WalkingPad to Applications (once; the link survives upgrades):
        ln -sf "#{opt_prefix}/WalkingPad.app" /Applications/WalkingPad.app
      Or open it directly:
        open "#{opt_prefix}/WalkingPad.app"

      macOS asks for Bluetooth access again after each upgrade.
    EOS
  end

  test do
    app = prefix/"WalkingPad.app"
    assert_predicate app/"Contents/MacOS/WalkingPad", :executable?
    system "codesign", "--verify", "--strict", app
  end
end
