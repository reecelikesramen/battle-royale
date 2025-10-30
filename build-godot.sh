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

# Check if macOS Rust target is installed (only target we build locally)
echo -e "${GREEN}Checking Rust target...${NC}"
MACOS_TARGET="aarch64-apple-darwin"

if rustup target list --installed | grep -q "^${MACOS_TARGET}$"; then
    echo -e "  ${GREEN}✓${NC} $MACOS_TARGET"
else
    echo -e "  ${YELLOW}⚠${NC} $MACOS_TARGET not installed, installing..."
    rustup target add "$MACOS_TARGET"
fi
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

# Build Rust libraries
echo -e "${GREEN}=== Building Rust Libraries ===${NC}"
cd "$PROJECT_ROOT/rust"

# Only build macOS ARM64 locally - Linux and Windows libraries come from CI artifacts
MACOS_TARGET="aarch64-apple-darwin"

echo ""
echo -e "${GREEN}Building for $MACOS_TARGET...${NC}"

# Set macOS-specific environment variables
export PROTOBUF_PREFIX=$(brew --prefix protobuf@21)
export OPENSSL_PREFIX=$(brew --prefix openssl)
export PKG_CONFIG_PATH="$OPENSSL_PREFIX/lib/pkgconfig:$PROTOBUF_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
export LDFLAGS="-L$OPENSSL_PREFIX/lib -L$PROTOBUF_PREFIX/lib"
export CPPFLAGS="-I$OPENSSL_PREFIX/include -I$PROTOBUF_PREFIX/include"
export CMAKE_PREFIX_PATH="$PROTOBUF_PREFIX:$CMAKE_PREFIX_PATH"

if cargo build --release --target "$MACOS_TARGET"; then
    echo -e "  ${GREEN}✓ Successfully built $MACOS_TARGET${NC}"
else
    echo -e "  ${RED}✗ Failed to build $MACOS_TARGET${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}Note: Linux and Windows libraries should be manually placed in target/release/${NC}"
echo -e "${YELLOW}      Expected files: librust.so (Linux) and rust.dll (Windows)${NC}"

echo ""
echo -e "${GREEN}=== Rust Libraries Built Successfully ===${NC}"
echo ""

# Verify libraries exist
echo -e "${GREEN}Verifying libraries...${NC}"

# Check macOS library (built locally)
if [ -f "target/aarch64-apple-darwin/release/librust.dylib" ]; then
    echo -e "  ${GREEN}✓ macOS ARM64 library (built locally)${NC}"
else
    echo -e "  ${RED}✗ macOS ARM64 library not found${NC}"
    exit 1
fi

# Check Linux library (from CI artifacts) - should be in rust/target/release/
if [ -f "$PROJECT_ROOT/rust/target/release/librust.so" ]; then
    echo -e "  ${GREEN}✓ Linux x86_64 library (from CI artifacts)${NC}"
else
    echo -e "  ${YELLOW}⚠ Linux x86_64 library not found in rust/target/release/${NC}"
    echo -e "  ${YELLOW}  Please download from CI and place librust.so in rust/target/release/${NC}"
fi

# Check Windows library (from CI artifacts) - should be in rust/target/release/
if [ -f "$PROJECT_ROOT/rust/target/release/rust.dll" ]; then
    echo -e "  ${GREEN}✓ Windows x86_64 library (from CI artifacts)${NC}"
else
    echo -e "  ${YELLOW}⚠ Windows x86_64 library not found in rust/target/release/${NC}"
    echo -e "  ${YELLOW}  Please download from CI and place rust.dll in rust/target/release/${NC}"
fi

echo ""

# Prepare libraries for Godot (copy to target/release for GDExtension paths)
echo -e "${GREEN}Preparing libraries for Godot export...${NC}"
mkdir -p target/release

# Copy macOS library from built target
cp target/aarch64-apple-darwin/release/librust.dylib target/release/librust.dylib
echo -e "  ${GREEN}✓ Copied macOS library${NC}"

# Linux and Windows libraries should already be in target/release/ from CI artifacts
# Just verify they exist
if [ -f "target/release/librust.so" ]; then
    echo -e "  ${GREEN}✓ Linux library ready${NC}"
else
    echo -e "  ${YELLOW}⚠ Linux library missing (will skip Linux exports)${NC}"
fi

if [ -f "target/release/rust.dll" ]; then
    echo -e "  ${GREEN}✓ Windows library ready${NC}"
else
    echo -e "  ${YELLOW}⚠ Windows library missing (will skip Windows exports)${NC}"
fi

echo ""

# Build Godot exports
cd "$PROJECT_ROOT"
OUTPUT_DIR="builds/$VERSION"
mkdir -p "$OUTPUT_DIR"

echo -e "${GREEN}=== Building Godot Exports ===${NC}"
cd godot

# Export presets from export_presets.cfg
# Only export presets if their corresponding libraries exist
PRESETS=(
    "macOS|macOS Dedicated Server|game-macos-arm64|server-macos-arm64|../rust/target/release/librust.dylib|app|app"
    "Linux|Linux Dedicated Server|game-linux-x86_64|server-linux-x86_64|../rust/target/release/librust.so|x86_64|x86_64"
    "Windows|Windows Dedicated Server|game-windows-x86_64|server-windows-x86_64|../rust/target/release/rust.dll|exe|exe"
)

for preset_group in "${PRESETS[@]}"; do
    IFS='|' read -r preset_game preset_server folder_game folder_server lib_path ext_game ext_server <<< "$preset_group"
    
    # Check if library exists (from godot/ directory, so use relative path)
    if [ ! -f "$lib_path" ]; then
        echo ""
        echo -e "${YELLOW}Skipping $preset_game and $preset_server (library not found: $lib_path)${NC}"
        continue
    fi
    
    # Export game preset
    echo ""
    echo -e "${GREEN}Exporting: $preset_game${NC}"
    game_folder="../$OUTPUT_DIR/$folder_game"
    mkdir -p "$game_folder"
    output_path="$game_folder/$folder_game.$ext_game"
    if godot --headless --verbose --export-release "$preset_game" "$output_path"; then
        echo -e "  ${GREEN}✓ Successfully exported $preset_game${NC}"
        
        # Create zip file
        echo -e "  ${GREEN}Creating zip archive...${NC}"
        cd "$game_folder"
        zip_name="../${folder_game}.zip"
        if [ "$ext_game" = "app" ]; then
            # For macOS .app bundles, zip the directory itself
            zip -r -q "$zip_name" "$folder_game.$ext_game"
        else
            # For other platforms, zip the file
            zip -q "$zip_name" "$folder_game.$ext_game"
        fi
        cd - > /dev/null
        echo -e "  ${GREEN}✓ Created $zip_name${NC}"
    else
        echo -e "  ${RED}✗ Failed to export $preset_game${NC}"
        exit 1
    fi
    
    # Export server preset
    echo ""
    echo -e "${GREEN}Exporting: $preset_server${NC}"
    server_folder="../$OUTPUT_DIR/$folder_server"
    mkdir -p "$server_folder"
    output_path="$server_folder/$folder_server.$ext_server"
    if godot --headless --verbose --export-release "$preset_server" "$output_path"; then
        echo -e "  ${GREEN}✓ Successfully exported $preset_server${NC}"
        
        # Create zip file
        echo -e "  ${GREEN}Creating zip archive...${NC}"
        cd "$server_folder"
        zip_name="../${folder_server}.zip"
        if [ "$ext_server" = "app" ]; then
            # For macOS .app bundles, zip the directory itself
            zip -r -q "$zip_name" "$folder_server.$ext_server"
        else
            # For other platforms, zip the file
            zip -q "$zip_name" "$folder_server.$ext_server"
        fi
        cd - > /dev/null
        echo -e "  ${GREEN}✓ Created $zip_name${NC}"
    else
        echo -e "  ${RED}✗ Failed to export $preset_server${NC}"
        exit 1
    fi
done

echo ""
echo -e "${GREEN}=== Build Complete ===${NC}"
echo -e "${GREEN}Builds available in: $OUTPUT_DIR${NC}"
echo ""
echo -e "${GREEN}Build folders:${NC}"
ls -ld "../$OUTPUT_DIR"/*/ 2>/dev/null | sed 's/^/  /' || true
echo ""
echo -e "${GREEN}Zip archives:${NC}"
ls -lh "../$OUTPUT_DIR"/*.zip 2>/dev/null | sed 's/^/  /' || true

