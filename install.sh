#!/bin/bash
# iVex 一键安装 (macOS)
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ivex-app/homebrew-ivex/main/install.sh)"
#   (也可以 curl -fsSL <地址> | bash —— 要输密码时从终端读)
#
# 流程:
#   1. 已经有 Homebrew: 跳过 Homebrew 安装, 直接 tap + 只信任 iVex 这一个配方 + `brew install --cask <tap>/ivex`。
#   2. 没有 Homebrew 的 Apple 芯片 Mac: 先装 Homebrew (连不上 GitHub 时改用清华镜像), 再用它装 iVex。
#   3. Intel 芯片的 Mac: Homebrew 官方安装脚本在 Intel 上直接退出 ("only supported on Apple Silicon"),
#      装不了 ⇒ 改为直接装 iVex 的安装包。Homebrew 安装或 brew 装 iVex 失败时也走这一条。
#   直接装安装包: 下载地址与 sha256 取自面板的检查更新接口 (最新正式版), 装前核对 sha256、
#   本团队的 Developer ID Installer 签名与 Gatekeeper (公证), 有一项不对就不装。
#
# 必须兼容 macOS 自带的 bash 3.2 (没有关联数组、没有 ${var,,})。不许以 root 运行 (Homebrew 也拒绝 root)。
set -u
set -o pipefail

# ---- 常量 (发版不用改) ----
IVEX_TAP="ivex-app/ivex"                 # = github.com/ivex-app/homebrew-ivex
IVEX_CASK="$IVEX_TAP/ivex"
IVEX_TEAM_ID="N9NUV88Q8Q"
IVEX_CHECK_BASE="https://basilica.ivexnet.com/agent/v1/client/check"
IVEX_APP="/Applications/iVex.app"
IVEX_MIN_MACOS_MAJOR=12
BREW_INSTALL_OFFICIAL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
TUNA="https://mirrors.tuna.tsinghua.edu.cn"
# 中科大镜像的安装脚本与官方相同; 清华没有可直接下载的 install.sh。
BREW_INSTALL_MIRROR="https://mirrors.ustc.edu.cn/misc/brew-install.sh"

# 测试开关 (正式使用不设):
#   IVEX_INSTALL_FORCE_DIRECT=1  不走 Homebrew, 直接装安装包
#   IVEX_INSTALL_FORCE_MIRROR=1  装 Homebrew 时当作连不上 GitHub, 用清华镜像
#   IVEX_INSTALL_DRY_RUN=1       只做检查与下载校验, 不安装 (不需要密码)
#   IVEX_INSTALL_TAP_URL=<git>   用这个地址的 tap 代替 GitHub 上的

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf '提示: %s\n' "$*" >&2; }
die()  { printf '\n安装未完成: %s\n' "$*" >&2; exit 1; }

# 要输密码时从终端读 (curl | bash 时标准输入是管道)。
# `[ -r /dev/tty ]` 在没有控制终端时 (ssh 不带 -t、自动化) 也为真, 真打开才报 "Device not configured" ⇒ 试开一次。
TTY_IN=/dev/stdin
if [ ! -t 0 ]; then
  if (: </dev/tty) 2>/dev/null; then TTY_IN=/dev/tty; else TTY_IN=/dev/null; fi
fi

WORK=""
SUDO_KEEPER=""
cleanup() {
  [ -z "$SUDO_KEEPER" ] || kill "$SUDO_KEEPER" >/dev/null 2>&1 || true
  [ -z "$WORK" ] || rm -rf "$WORK"
}
trap cleanup EXIT

# ---- 环境检查 ----
[ "$(uname -s)" = "Darwin" ] || die "这个脚本只能在 macOS 上运行。"
[ "${EUID:-$(id -u)}" != 0 ] || die "请不要用 sudo 或 root 运行，直接用普通账户运行即可；需要时脚本会请您输入密码。"

MACOS_VERSION=$(/usr/bin/sw_vers -productVersion)
MACOS_MAJOR=${MACOS_VERSION%%.*}
case "$MACOS_MAJOR" in ''|*[!0-9]*) die "无法识别系统版本: $MACOS_VERSION" ;; esac
[ "$MACOS_MAJOR" -ge "$IVEX_MIN_MACOS_MAJOR" ] || die "iVex 需要 macOS 12 或更高版本，这台 Mac 是 macOS $MACOS_VERSION。"

# Rosetta 下 uname -m 也报 x86_64, 用 sysctl 认真实芯片。
if [ "$(/usr/sbin/sysctl -in hw.optional.arm64 2>/dev/null)" = "1" ]; then ARCH=arm64; else ARCH=x86_64; fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ivex-install.XXXXXX") || die "无法创建临时目录。"

# ---- 管理员密码 ----
sudo_ready() {
  [ "${IVEX_INSTALL_DRY_RUN:-}" = 1 ] && return 0
  if ! /usr/bin/sudo -n true 2>/dev/null; then
    say "安装需要管理员权限，请输入这台 Mac 的登录密码（输入时不显示）。"
    /usr/bin/sudo -v <"$TTY_IN" || die "没有拿到管理员权限。"
  fi
  # 安装 Homebrew 与命令行工具可能要好几分钟, 期间保持授权不过期。
  if [ -z "$SUDO_KEEPER" ]; then
    ( while kill -0 "$$" 2>/dev/null; do /usr/bin/sudo -n true 2>/dev/null; sleep 50; done ) &
    SUDO_KEEPER=$!
    disown "$SUDO_KEEPER" 2>/dev/null || true   # 结束时杀掉它不打印 "Terminated"
  fi
}

# ---- Homebrew ----
find_brew() {
  local b
  b=$(command -v brew 2>/dev/null || true)
  if [ -n "$b" ] && [ -x "$b" ]; then printf '%s' "$b"; return 0; fi
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$b" ]; then printf '%s' "$b"; return 0; fi
  done
  return 1
}

github_reachable() {
  [ "${IVEX_INSTALL_FORCE_MIRROR:-}" = 1 ] && return 1
  /usr/bin/curl -fsS -o /dev/null --connect-timeout 6 --max-time 12 "$BREW_INSTALL_OFFICIAL" 2>/dev/null
}

# 写进登录 shell 的配置: 以后新开的终端能直接用 brew (官方脚本只提示、不写)。只追加一次。
persist_brew_env() {
  local brew_bin=$1 use_mirror=$2 profile marker="# iVex 安装脚本添加 (Homebrew)"
  case "$(basename "${SHELL:-/bin/zsh}")" in
    bash) profile="$HOME/.bash_profile" ;;
    *)    profile="$HOME/.zprofile" ;;
  esac
  if [ -f "$profile" ] && grep -qF "$marker" "$profile"; then return 0; fi
  {
    printf '\n%s\n' "$marker"
    if [ "$use_mirror" = 1 ]; then
      printf 'export HOMEBREW_BREW_GIT_REMOTE="%s"\n' "$TUNA/git/homebrew/brew.git"
      printf 'export HOMEBREW_API_DOMAIN="%s"\n' "$TUNA/homebrew-bottles/api"
      printf 'export HOMEBREW_BOTTLE_DOMAIN="%s"\n' "$TUNA/homebrew-bottles"
    fi
    printf 'eval "$(%s shellenv)"\n' "$brew_bin"
  } >>"$profile" && say "已把 Homebrew 加入 $profile，新开的终端窗口可以直接使用 brew。"
}

install_brew() {
  local script="$WORK/brew-install.sh" use_mirror=0
  step "安装 Homebrew（如果这台 Mac 没有苹果的命令行工具，会先下载安装，可能需要 10–30 分钟，请保持联网）"
  if github_reachable; then
    /usr/bin/curl -fsSL --max-time 120 -o "$script" "$BREW_INSTALL_OFFICIAL" || return 1
  else
    say "无法连接 GitHub，改用国内镜像（中国科学技术大学、清华大学）安装 Homebrew。"
    use_mirror=1
    /usr/bin/curl -fsSL --max-time 120 -o "$script" "$BREW_INSTALL_MIRROR" || return 1
    export HOMEBREW_BREW_GIT_REMOTE="$TUNA/git/homebrew/brew.git"
    export HOMEBREW_API_DOMAIN="$TUNA/homebrew-bottles/api"
    export HOMEBREW_BOTTLE_DOMAIN="$TUNA/homebrew-bottles"
  fi
  sudo_ready
  # 授权已缓存 ⇒ 官方脚本的 `sudo -n` 能过; NONINTERACTIVE 省掉它的「按回车继续」。
  NONINTERACTIVE=1 /bin/bash "$script" </dev/null || return 1
  local brew_bin
  brew_bin=$(find_brew) || return 1
  eval "$("$brew_bin" shellenv)"
  persist_brew_env "$brew_bin" "$use_mirror"
  printf '%s' "$brew_bin" >"$WORK/brew-path"
  return 0
}

install_with_brew() {
  local brew_bin=$1
  step "用 Homebrew 安装 iVex"
  # 不顺带更新 Homebrew 自己: 慢, 国内常卡住, 且不是装 iVex 所必需。
  export HOMEBREW_NO_AUTO_UPDATE=1
  if "$brew_bin" list --cask "$IVEX_CASK" >/dev/null 2>&1; then
    say "iVex 已经通过 Homebrew 安装。以后 iVex 会在 App 内自动更新。"
    return 0
  fi
  sudo_ready
  if [ -n "${IVEX_INSTALL_TAP_URL:-}" ]; then
    "$brew_bin" tap "$IVEX_TAP" "$IVEX_INSTALL_TAP_URL" || return 1
  else
    "$brew_bin" tap "$IVEX_TAP" || return 1
  fi
  # Homebrew 6 起第三方 tap 默认不受信任: 不信任时 install 之后的 upgrade / uninstall 会拒绝读配方
  # ("Refusing to load cask … from untrusted tap")。只信任 iVex 这一个配方, 不信任整个 tap。
  # 老版本 Homebrew 没有 trust 命令, 也没有这条限制 ⇒ 没有就跳过。
  if "$brew_bin" commands 2>/dev/null | grep -qx trust; then
    "$brew_bin" trust --cask "$IVEX_CASK" || return 1
  fi
  "$brew_bin" install --cask "$IVEX_CASK" <"$TTY_IN"
}

# ---- 直接装安装包 ----
json_field() { # json_field <文件> <键路径>, 例如 update.url
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

install_direct() {
  local check="$WORK/check.json" pkg="$WORK/iVex.pkg" url sha size version i urls_count got sig leaf gk progress
  step "下载 iVex 安装包"
  # 服务器返回最新的正式版; 不带设备标识, 不计入任何统计。
  # 限流时 (429) 按 Retry-After 等一次再试。
  local code wait
  for i in 1 2; do
    code=$(/usr/bin/curl -sSL --max-time 30 -A "iVex-Installer/1 (macOS $MACOS_VERSION; $ARCH)" \
        -D "$WORK/check.headers" -o "$check" -w '%{http_code}' \
        "$IVEX_CHECK_BASE?platform=macos&arch=$ARCH&version=0.0.0&channel=stable" 2>/dev/null) || code=000
    [ "$code" = 429 ] || break
    wait=$(tr -d '\r' <"$WORK/check.headers" | awk 'tolower($1)=="retry-after:" {print $2}' | tail -1)
    case "$wait" in ''|*[!0-9]*) wait=5 ;; esac
    [ "$wait" -le 60 ] || wait=60
    say "服务器繁忙，${wait} 秒后重试…"
    sleep "$wait"
  done
  [ "$code" = 200 ] || die "无法连接 iVex 服务器获取下载地址（$code），请检查网络后重试。"
  version=$(json_field "$check" update.version) || version=""
  sha=$(json_field "$check" update.sha256 | tr 'A-F' 'a-f') || sha=""
  size=$(json_field "$check" update.size) || size=""
  case "$sha" in [0-9a-f]*) [ ${#sha} = 64 ] || sha="" ;; *) sha="" ;; esac
  [ -n "$version" ] && [ -n "$sha" ] || die "服务器没有给出可用的安装包信息。"

  # 主地址 + 备用地址 (urls 数组), 依次尝试。
  urls_count=$(/usr/bin/plutil -extract update.urls raw -o - "$check" 2>/dev/null || echo 0)
  case "$urls_count" in ''|*[!0-9]*) urls_count=0 ;; esac
  got=0
  for url in "$(json_field "$check" update.url)" $(i=0; while [ $i -lt "$urls_count" ]; do json_field "$check" "update.urls.$i"; echo; i=$((i + 1)); done); do
    case "$url" in https://*) ;; *) continue ;; esac
    say "iVex $version：$url"
    progress=-sS; [ -t 2 ] && progress=--progress-bar
    if /usr/bin/curl -fL "$progress" --connect-timeout 15 --max-time 1800 -o "$pkg" "$url"; then
      if [ "$(/usr/bin/shasum -a 256 "$pkg" | awk '{print $1}')" = "$sha" ]; then got=1; break; fi
      warn "下载的文件与服务器公布的指纹不一致，换一个地址重试。"
    fi
  done
  [ "$got" = 1 ] || die "安装包下载失败或校验不通过。"
  [ -z "$size" ] || [ "$(/usr/bin/stat -f %z "$pkg")" = "$size" ] || die "安装包大小与服务器公布的不一致。"

  step "核对安装包签名"
  sig=$(/usr/sbin/pkgutil --check-signature "$pkg" 2>/dev/null) || die "安装包没有有效签名。"
  leaf=$(printf '%s\n' "$sig" | grep -E '^ *1\. ' | head -1 | sed 's/^ *//; s/ *$//')
  printf '%s\n' "$sig" | grep -q "signed by a developer certificate issued by Apple for distribution" \
    && printf '%s\n' "$leaf" | grep -Eq "^1\. Developer ID Installer:.*\(${IVEX_TEAM_ID}\)$" \
    || die "安装包不是 iVex 团队签名的，已停止安装。"
  gk=$(/usr/sbin/spctl --assess --type install -vv "$pkg" 2>&1 || true)
  printf '%s\n' "$gk" | grep -q "accepted" || die "macOS 未认可这个安装包（公证检查未通过），已停止安装。"
  say "签名正确：$leaf"

  if [ "${IVEX_INSTALL_DRY_RUN:-}" = 1 ]; then say "（试运行，不安装）"; return 0; fi
  step "安装 iVex $version"
  sudo_ready
  /usr/bin/sudo /usr/sbin/installer -pkg "$pkg" -target / || die "安装程序报错，请稍后重试或联系客服。"
}

# ---- 主流程 ----
say "iVex 安装程序（macOS $MACOS_VERSION，$( [ "$ARCH" = arm64 ] && echo Apple 芯片 || echo Intel 芯片)）"

if [ "${IVEX_INSTALL_FORCE_DIRECT:-}" = 1 ]; then
  install_direct
elif BREW=$(find_brew); then
  say "已检测到 Homebrew（$BREW），跳过 Homebrew 安装。"
  if [ "${IVEX_INSTALL_DRY_RUN:-}" = 1 ]; then say "（试运行，不安装）"
  elif ! install_with_brew "$BREW"; then
    warn "通过 Homebrew 安装 iVex 未成功，改为直接安装。"
    install_direct
  fi
elif [ "$ARCH" != arm64 ]; then
  say "Homebrew 已不支持 Intel 芯片的 Mac，改为直接安装 iVex。"
  install_direct
elif [ "${IVEX_INSTALL_DRY_RUN:-}" = 1 ]; then
  say "（试运行：将先安装 Homebrew，再安装 iVex）"
  install_direct
elif install_brew; then
  if ! install_with_brew "$(cat "$WORK/brew-path")"; then
    warn "通过 Homebrew 安装 iVex 未成功，改为直接安装。"
    install_direct
  fi
else
  warn "Homebrew 安装未成功，改为直接安装 iVex。"
  install_direct
fi

if [ "${IVEX_INSTALL_DRY_RUN:-}" != 1 ]; then
  [ -d "$IVEX_APP" ] || die "没有在「应用程序」里找到 iVex。"
  step "安装完成"
  say "iVex 已安装到「应用程序」。首次打开时，请按提示允许 iVex 添加网络扩展和 VPN 配置。"
  /usr/bin/pgrep -xq iVex || /usr/bin/open "$IVEX_APP" >/dev/null 2>&1 || true
fi
