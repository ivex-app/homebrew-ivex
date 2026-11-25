# iVex 的 Homebrew 配方 (cask)。每次正式版发布后更新 version / sha256 / url 三行。
#
# 安装: brew install --cask ivex-app/ivex/ivex   (写全名时 Homebrew 6 只信任这一个配方, 不需要 brew trust)
cask "ivex" do
  version "3.0.1,978"
  sha256 "19110f4696abb8e7dcb8cabacc50227ca163d33f5da1110ae6482d588329e698"

  # 面板的下载地址按文件编号, 不带版本号; 下载时文件名取自 Content-Disposition (iVex-<版本>-b<构建号>.pkg)。
  url "https://basilica.ivexnet.com/agent/v1/d/cfile_01M6C1H0M0X2YVPDX3JBN6KFXB"
  name "iVex"
  desc "Network acceleration client"
  homepage "https://basilica.ivexnet.com/"

  # 装好以后由 App 自己更新 (Sparkle), brew upgrade 默认不动它。
  auto_updates true
  depends_on macos: :monterey   # 新写法即「Monterey 或更新」(旧的 ">= :monterey" 会报过时警告)

  pkg "iVex-#{version.csv.first}-b#{version.csv.second}.pkg"

  # 网络扩展与 VPN 配置只能由 App 自己移除 (系统不给命令行的卸载办法) ⇒ 先在 App 里「移除 iVex」, 再 brew uninstall。
  uninstall quit:    "com.ivex.mac-client",
            pkgutil: "com.ivex.mac-client",
            delete:  "/Applications/iVex.app"

  zap trash: [
    "~/Library/Caches/com.ivex.mac-client",
    "~/Library/HTTPStorages/com.ivex.mac-client",
    "~/Library/Preferences/com.ivex.mac-client.plist",
    "~/Library/Saved Application State/com.ivex.mac-client.savedState",
  ]

  caveats <<~EOS
    卸载 iVex 之前，请先在 iVex 的「设置 → 移除 iVex」中移除网络扩展和 VPN 配置，
    然后再运行 brew uninstall --cask ivex。
  EOS
end
