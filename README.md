# iVex Homebrew Tap

Install iVex for macOS (macOS 12 or later):

```bash
brew install --cask ivex-app/ivex/ivex
```

Or use the one-line installer, which also installs Homebrew if needed:

```bash
/bin/bash -c "$(curl -fsSL https://basilica.ivexnet.com/agent/v1/d/mac-install.sh)"
```

iVex updates itself after installation.

Before uninstalling, open iVex and choose **Settings → Remove iVex…** to remove the network extension and VPN configuration, then run:

```bash
brew uninstall --cask ivex
```
