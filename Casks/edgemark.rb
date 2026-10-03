cask "edgemark" do
  version "2.13.0"
  sha256 "eb74b32d98e799346fef498df158e13fcdef13b8ad710ef542c78049f395f925"

  url "https://github.com/jonaprieto/EdgeMark/releases/download/v#{version}/EdgeMark-v#{version}.dmg"
  name "EdgeMark"
  desc "Side-panel Markdown notes app with GitHub and gist sync (personal fork)"
  homepage "https://github.com/jonaprieto/EdgeMark"

  # Same app and bundle identifier as Ender-Wang's EdgeMark, so only one can be installed.
  conflicts_with cask: "ender-wang/tap/edgemark"
  depends_on macos: :sequoia

  app "EdgeMark.app"

  # The build is ad-hoc signed and not notarized, so clear the quarantine flag.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-cr", "{{appdir}}/EdgeMark.app"]
  end

  zap trash: [
    "~/Library/Caches/io.github.ender-wang.EdgeMark",
    "~/Library/Preferences/io.github.ender-wang.EdgeMark.plist",
  ]
end
