#!/bin/bash
set -e

# Build script for macOS that builds Godot exports for all platforms
# This script builds Rust libraries for each target and then exports Godot projects

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

echo -e "${GREEN}=== Godot Build Script ===${NC}"

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${RED}Error: Not in a git repository${NC}"
    exit 1
fi

# Determine version string
GIT_STATUS=$(git status --porcelain)
GIT_HASH=$(git rev-parse --short HEAD)

if [ -z "$GIT_STATUS" ]; then
    # Clean working directory - check if HEAD is tagged
    CURRENT_TAG=$(git describe --exact-match --tags HEAD 2>/dev/null || echo "")
    if [ -n "$CURRENT_TAG" ]; then
        VERSION="$CURRENT_TAG"
        echo -e "${GREEN}Using git tag: $VERSION${NC}"
    else
        DATE=$(date +%Y%m%d)
        VERSION="${DATE}-${GIT_HASH}"
        echo -e "${YELLOW}Using date and hash: $VERSION${NC}"
    fi
else
    # Dirty working directory - use date and hash
    DATE=$(date +%Y%m%d)
    VERSION="${DATE}-${GIT_HASH}-dirty"
    echo -e "${YELLOW}Working directory is dirty, using: $VERSION${NC}"
fi

echo -e "${GREEN}Build version: $VERSION${NC}"
echo ""

# Check for required tools
command -v rustc > /dev/null || { echo -e "${RED}Error: rustc not found. Please install Rust.${NC}"; exit 1; }
command -v cargo > /dev/null || { echo -e "${RED}Error: cargo not found. Please install Rust.${NC}"; exit 1; }
command -v godot > /dev/null || { echo -e "${RED}Error: godot not found. Please install Godot 4.5.${NC}"; exit 1; }

# Check if cross-compilation targets are installed
echo -e "${GREEN}Checking Rust targets...${NC}"
TARGETS=(
    "aarch64-apple-darwin"
    "x86_64-unknown-linux-gnu"
    "x86_64-pc-windows-msvc"
)

for target in "${TARGETS[@]}"; do
    if rustup target list --installed | grep -q "^${target}$"; then
        echo -e "  ${GREEN}✓${NC} $target"
    else
        echo -e "  ${YELLOW}⚠${NC} $target not installed, installing..."
        rustup target add "$target"
    fi
done
echo ""

# Check for required tools for cross-compilation
echo -e "${GREEN}Checking cross-compilation tools...${NC}"

# Check for Linux cross-compilation (needs musl or gnu toolchain)
if ! command -v x86_64-linux-gnu-gcc > /dev/null 2>&1; then
    echo -e "  ${YELLOW}Warning: x86_64-linux-gnu-gcc not found. Linux builds may fail.${NC}"
    echo -e "  ${YELLOW}Install with: brew install SergioBenitez/osxct/x86_64-unknown-linux-gnu${NC}"
fi

# Windows cross-compilation typically works without extra tools on macOS
echo ""

# Install macOS dependencies
echo -e "${GREEN}Installing macOS dependencies...${NC}"
if ! brew list openssl > /dev/null 2>&1; then
    echo "Installing openssl..."
    brew install openssl
fi

if ! brew list protobuf@21 > /dev/null 2>&1; then
    echo "Installing protobuf@21..."
    brew install protobuf@21
    brew unlink protobuf@21 2>/dev/null || true
    brew link --force protobuf@21
fi

if ! brew list pkg-config > /dev/null 2>&1; then
    echo "Installing pkg-config..."
    brew install pkg-config
fi
echo ""

# Set up environment variables for macOS dependencies
export PROTOBUF_PREFIX=$(brew --prefix protobuf@21)
export OPENSSL_PREFIX=$(brew --prefix openssl)
export PKG_CONFIG_PATH="$OPENSSL_PREFIX/lib/pkgconfig:$PROTOBUF_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
export LDFLAGS="-L$OPENSSL_PREFIX/lib -L$PROTOBUF_PREFIX/lib"
export CPPFLAGS="-I$OPENSSL_PREFIX/include -I$PROTOBUF_PREFIX/include"
export CMAKE_PREFIX_PATH="$PROTOBUF_PREFIX:$CMAKE_PREFIX_PATH"

# Build Rust libraries for each target
echo -e "${GREEN}=== Building Rust Libraries ===${NC}"
cd "$PROJECT_ROOT/rust"

for target in "${TARGETS[@]}"; do
    echo ""
    echo -e "${GREEN}Building for $target...${NC}"
    
    # Set platform-specific environment variables
    unset CMAKE_PREFIX_PATH
    unset PKG_CONFIG_PATH
    unset LDFLAGS
    unset CPPFLAGS
    
    if [ "$target" = "aarch64-apple-darwin" ]; then
        # macOS ARM64 - use brew-installed dependencies
        export PROTOBUF_PREFIX=$(brew --prefix protobuf@21)
        export OPENSSL_PREFIX=$(brew --prefix openssl)
        export PKG_CONFIG_PATH="$OPENSSL_PREFIX/lib/pkgconfig:$PROTOBUF_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
        export LDFLAGS="-L$OPENSSL_PREFIX/lib -L$PROTOBUF_PREFIX/lib"
        export CPPFLAGS="-I$OPENSSL_PREFIX/include -I$PROTOBUF_PREFIX/include"
        export CMAKE_PREFIX_PATH="$PROTOBUF_PREFIX:$CMAKE_PREFIX_PATH"
    elif [ "$target" = "x86_64-unknown-linux-gnu" ]; then
        # Linux - may need special configuration
        echo -e "  ${YELLOW}Note: Linux cross-compilation may require additional setup${NC}"
    elif [ "$target" = "x86_64-pc-windows-msvc" ]; then
        # Windows - usually works without extra config
        echo -e "  ${YELLOW}Note: Windows cross-compilation requires Windows SDK (usually auto-detected)${NC}"
    fi
    
    if cargo build --release --target "$target"; then
        echo -e "  ${GREEN}✓ Successfully built $target${NC}"
    else
        echo -e "  ${RED}✗ Failed to build $target${NC}"
        exit 1
    fi
done

echo ""
echo -e "${GREEN}=== Rust Libraries Built Successfully ===${NC}"
echo ""

# Verify libraries exist
echo -e "${GREEN}Verifying built libraries...${NC}"
if [ -f "target/aarch64-apple-darwin/release/librust.dylib" ]; then
    echo -e "  ${GREEN}✓ macOS ARM64 library${NC}"
else
    echo -e "  ${RED}✗ macOS ARM64 library not found${NC}"
    exit 1
fi

if [ -f "target/x86_64-unknown-linux-gnu/release/librust.so" ]; then
    echo -e "  ${GREEN}✓ Linux x86_64 library${NC}"
else
    echo -e "  ${RED}✗ Linux x86_64 library not found${NC}"
    exit 1
fi

if [ -f "target/x86_64-pc-windows-msvc/release/rust.dll" ]; then
    echo -e "  ${GREEN}✓ Windows x86_64 library${NC}"
else
    echo -e "  ${RED}✗ Windows x86_64 library not found${NC}"
    exit 1
fi

echo ""

# Prepare libraries for Godot (copy to target/release for GDExtension paths)
echo -e "${GREEN}Preparing libraries for Godot export...${NC}"
mkdir -p target/release

# Copy each library to target/release/ with the name GDExtension expects
cp target/aarch64-apple-darwin/release/librust.dylib target/release/librust.dylib
cp target/x86_64-unknown-linux-gnu/release/librust.so target/release/librust.so
cp target/x86_64-pc-windows-msvc/release/rust.dll target/release/rust.dll

echo -e "  ${GREEN}✓ Libraries prepared${NC}"
echo ""

# Build Godot exports
cd "$PROJECT_ROOT"
OUTPUT_DIR="builds/$VERSION"
mkdir -p "$OUTPUT_DIR"

echo -e "${GREEN}=== Building Godot Exports ===${NC}"
cd godot

# Export presets from export_presets.cfg
PRESETS=(
    "macOS"
    "macOS Dedicated Server"
    "Linux"
    "Linux Dedicated Server"
    "Windows"
    "Windows Dedicated Server"
)

# Output filenames matching the CI naming
OUTPUTS=(
    "game-macos-arm64.app"
    "server-macos-arm64.app"
    "game-linux-x86_64.x86_64"
    "server-linux-x86_64.x86_64"
    "game-windows-x86_64.exe"
    "server-windows-x86_64.exe"
)

for i in "${!PRESETS[@]}"; do
    preset="${PRESETS[$i]}"
    output="${OUTPUTS[$i]}"
    
    echo ""
    echo -e "${GREEN}Exporting: $preset${NC}"
    
    output_path="../$OUTPUT_DIR/$output"
    
    if godot --headless --verbose --export-release "$preset" "$output_path"; then
        echo -e "  ${GREEN}✓ Successfully exported $preset${NC}"
    else
        echo -e "  ${RED}✗ Failed to export $preset${NC}"
        exit 1
    fi
done

echo ""
echo -e "${GREEN}=== Build Complete ===${NC}"
echo -e "${GREEN}Builds available in: $OUTPUT_DIR${NC}"
echo ""
ls -lh "../$OUTPUT_DIR/"

