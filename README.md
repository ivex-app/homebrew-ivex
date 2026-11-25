# iVex Homebrew Tap

Install iVex for macOS (macOS 12 or later):

```bash
brew install --cask ivex-app/ivex/ivex
```

Or use the one-line installer. It installs Homebrew first if needed (on Intel Macs, where Homebrew is no longer supported, it installs the iVex package directly):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ivex-app/homebrew-ivex/main/install.sh)"
```

iVex updates itself after installation.

Before uninstalling, open iVex and choose **Settings → Remove iVex…** to remove the network extension and VPN configuration, then run:

```bash
brew uninstall --cask ivex
```
