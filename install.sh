#!/usr/bin/env bash
# Install mycelium: framework checkout + CLI on PATH.
#
#   curl -fsSL https://raw.githubusercontent.com/srivtx/mycelium/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --with-toolchain
#
# Environment:
#   MYCELIUM_HOME              install location (default: ~/.local/share/mycelium)
#   MYCELIUM_INSTALL_BRANCH    git branch (default: main)
#   MYCELIUM_INSTALL_REPO      git URL (default: https://github.com/srivtx/mycelium.git)

set -euo pipefail

REPO="${MYCELIUM_INSTALL_REPO:-https://github.com/srivtx/mycelium.git}"
BRANCH="${MYCELIUM_INSTALL_BRANCH:-main}"
HOME_DIR="${MYCELIUM_HOME:-$HOME/.local/share/mycelium}"
BIN_DIR="${HOME}/.local/bin"
WITH_TOOLCHAIN=0

for arg in "$@"; do
    case "$arg" in
        --with-toolchain) WITH_TOOLCHAIN=1 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            echo ""
            echo "Options:"
            echo "  --with-toolchain   Also install zig, llvm@21, rust/cargo, sbpf-linker, solana-cli (macOS: brew where available)"
            exit 0
            ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 1 ;;
    esac
done

info() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: required command not found: $1" >&2
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Clone or update framework
# ---------------------------------------------------------------------------
if [ -d "$HOME_DIR/.git" ]; then
    info "Updating mycelium at $HOME_DIR"
    git -C "$HOME_DIR" fetch origin "$BRANCH" --quiet
    git -C "$HOME_DIR" checkout "$BRANCH" --quiet 2>/dev/null || true
    git -C "$HOME_DIR" pull --ff-only origin "$BRANCH" --quiet 2>/dev/null || \
        git -C "$HOME_DIR" reset --hard "origin/$BRANCH" --quiet
else
    info "Cloning mycelium into $HOME_DIR"
    mkdir -p "$(dirname "$HOME_DIR")"
    need_cmd git
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$HOME_DIR"
fi

# ---------------------------------------------------------------------------
# CLI symlink
# ---------------------------------------------------------------------------
mkdir -p "$BIN_DIR"
chmod +x "$HOME_DIR/tools/mycelium"
ln -sf "$HOME_DIR/tools/mycelium" "$BIN_DIR/mycelium"
info "Linked $BIN_DIR/mycelium"

# ---------------------------------------------------------------------------
# Shell rc hints
# ---------------------------------------------------------------------------
append_once() {
    local line="$1"
    local rc="$2"
    [ -f "$rc" ] || return 0
    grep -Fq "$line" "$rc" 2>/dev/null && return 0
    printf '\n# mycelium\n%s\n' "$line" >> "$rc"
}

export_line="export MYCELIUM_HOME=\"$HOME_DIR\""
path_line='export PATH="$HOME/.local/bin:$PATH"'

for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    append_once "$export_line" "$rc"
    append_once "$path_line" "$rc"
done

export MYCELIUM_HOME="$HOME_DIR"
export PATH="$BIN_DIR:$PATH"

# ---------------------------------------------------------------------------
# Optional toolchain
# ---------------------------------------------------------------------------
if [ "$WITH_TOOLCHAIN" = 1 ]; then
    info "Installing toolchain dependencies (--with-toolchain)"

    if command -v brew >/dev/null 2>&1; then
        brew list zig &>/dev/null || brew install zig
        brew list llvm@21 &>/dev/null || brew install llvm@21
        mkdir -p "$HOME/.cargo/lib"
        LLVM_PREFIX="$(brew --prefix llvm@21 2>/dev/null || true)"
        if [ -n "$LLVM_PREFIX" ] && [ -d "$LLVM_PREFIX/lib" ]; then
            ln -sf "$LLVM_PREFIX/lib/libLLVM.dylib" "$HOME/.cargo/lib/libLLVM.dylib" 2>/dev/null || true
            ln -sf "$LLVM_PREFIX/lib/libLLVM-21.dylib" "$HOME/.cargo/lib/libLLVM-21.dylib" 2>/dev/null || true
        fi
    else
        warn "Homebrew not found; install zig and llvm@21 manually (see docs/QUICKSTART.md)"
    fi

    if ! command -v cargo >/dev/null 2>&1; then
        if command -v rustup >/dev/null 2>&1; then
            rustup default stable
        else
            info "Installing rustup"
            curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
            # shellcheck source=/dev/null
            [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
        fi
    fi

    if command -v cargo >/dev/null 2>&1; then
        cargo install sbpf-linker --locked 2>/dev/null || cargo install sbpf-linker
    else
        warn "cargo not available; run: cargo install sbpf-linker"
    fi

    if ! command -v solana >/dev/null 2>&1; then
        info "Installing solana-cli (Anza)"
        sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)" || warn "solana install failed; install manually"
        export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"
    fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
info "mycelium installed"
echo ""
echo "  export MYCELIUM_HOME=\"$HOME_DIR\""
echo "  export PATH=\"$BIN_DIR:\$PATH\""
echo ""
echo "  mycelium doctor          # check toolchain"
echo "  mycelium init demo       # scaffold a program"
echo "  cd demo && mycelium build"
echo ""

if command -v mycelium >/dev/null 2>&1; then
    mycelium doctor || true
fi
