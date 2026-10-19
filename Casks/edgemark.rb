cask "edgemark" do
  version "2.17.0"
  sha256 "3acd39784ebe58a97c56a4ee038ae9dc77d28c602223aed52554b44216e60a71"

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
