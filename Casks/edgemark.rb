cask "edgemark" do
  version "2.16.0"
  sha256 "790865fb4da81bd0fedec5869093f80b67992d08c7b904bc192224a2441d85f4"

  url "https://github.com/jonaprieto/EdgeMark/releases/download/v#{version}/EdgeMark-v#{version}.dmg"
  name "EdgeMark"
  desc "Side-panel Markdown notes app with GitHub and gist sync (personal fork)"
  homepage "https://github.com/jonaprieto/EdgeMark"

  # Same token and bundle identifier as Ender-Wang's EdgeMark, so only one of them can be installed;
  # always use the full name jonaprieto/tap/edgemark.
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
