#!/bin/bash
set -e

# Get current directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

# Setup ANGLE if needed
if [ ! -d "angle" ]; then
    source ./setup-angle-mac.sh
else
    # Add depot_tools to PATH
    export PATH="$PATH:$SCRIPT_DIR/depot_tools"
fi

# Go to ANGLE directory
cd angle

# Common GN args for all iOS builds
COMMON_ARGS='
    is_debug=false
    ios_enable_code_signing=false
    is_component_build=false
    angle_enable_metal=true
    angle_standalone=true
    angle_build_tests=false

    # Enable official build optimizations
    is_official_build=true
    chrome_pgo_phase=0

    # Disable unused backends
    angle_enable_d3d9=false
    angle_enable_d3d11=false
    angle_enable_gl=false
    angle_enable_null=false
    angle_enable_vulkan=false
    angle_enable_wgpu=false

    # Language settings
    angle_enable_essl=false
    angle_enable_glsl=true

    # Optimize for size
    symbol_level=0
    strip_debug_info=true
    angle_enable_trace=false
    ios_deployment_target="16.0"
'

# Build for iOS ARM64 (device)
echo "Building ANGLE for iOS ARM64 (device)..."
gn gen out/ios-release-arm64 --args="
    target_os=\"ios\"
    target_cpu=\"arm64\"
    target_environment=\"device\"
    $COMMON_ARGS
"
ninja -C out/ios-release-arm64 libEGL libGLESv2

# Copy the frameworks to build directory
rm -rf ../build/ios/arm64/*
mkdir -p ../build/ios/arm64
cp -R out/ios-release-arm64/*.framework ../build/ios/arm64/

# Build for iOS ARM64 Simulator
echo "Building ANGLE for iOS ARM64 Simulator..."
gn gen out/ios-release-simulator-arm64 --args="
    target_os=\"ios\"
    target_cpu=\"arm64\"
    target_environment=\"simulator\"
    $COMMON_ARGS
"
ninja -C out/ios-release-simulator-arm64 libEGL libGLESv2

# Copy the frameworks to build directory
rm -rf ../build/ios/simulator-arm64/*
mkdir -p ../build/ios/simulator-arm64
cp -R out/ios-release-simulator-arm64/*.framework ../build/ios/simulator-arm64/

# Build for iOS x86_64 Simulator
echo "Building ANGLE for iOS x86_64 Simulator..."
gn gen out/ios-release-simulator-x86_64 --args="
    target_os=\"ios\"
    target_cpu=\"x64\"
    target_environment=\"simulator\"
    $COMMON_ARGS
"
ninja -j 10 -k1 -C out/ios-release-simulator-x86_64 libEGL libGLESv2

# Copy the frameworks to build directory
rm -rf ../build/ios/simulator-x86_64/*
mkdir -p ../build/ios/simulator-x86_64
cp -R out/ios-release-simulator-x86_64/*.framework ../build/ios/simulator-x86_64/

cd ..

# Create unified simulator binaries using lipo
echo "Creating unified simulator binaries..."
mkdir -p build/ios/simulator-combined

# Get list of all frameworks from simulator-arm64 build
FRAMEWORKS=$(ls build/ios/simulator-arm64/)

# Create combined simulator frameworks
for FRAMEWORK in $FRAMEWORKS; do
    echo "Creating combined simulator framework for $FRAMEWORK..."

    # Extract the base name without the .framework extension
    FRAMEWORK_BASE=$(basename "$FRAMEWORK" .framework)

    # Create directory structure for the combined simulator framework
    mkdir -p "build/ios/simulator-combined/$FRAMEWORK"

    # Copy the framework structure from the ARM64 simulator build (we'll replace the binary)
    cp -R "build/ios/simulator-arm64/$FRAMEWORK/" "build/ios/simulator-combined/"

    # Find binary paths - they should have the same name as the framework
    ARM64_SIM_BINARY="build/ios/simulator-arm64/$FRAMEWORK/$FRAMEWORK_BASE"
    X86_64_SIM_BINARY="build/ios/simulator-x86_64/$FRAMEWORK/$FRAMEWORK_BASE"
    COMBINED_SIM_BINARY="build/ios/simulator-combined/$FRAMEWORK/$FRAMEWORK_BASE"

    # Create the combined binary using lipo
    lipo -create -output "$COMBINED_SIM_BINARY" "$ARM64_SIM_BINARY" "$X86_64_SIM_BINARY"

    # The simulator build of ANGLE does not emit an Info.plist in its
    # framework bundles (the device build does). Xcode refuses to embed a
    # framework without one, so synthesize it from the device framework's
    # Info.plist with the platform fields adjusted.
    COMBINED_SIM_PLIST="build/ios/simulator-combined/$FRAMEWORK/Info.plist"
    DEVICE_PLIST="build/ios/arm64/$FRAMEWORK/Info.plist"
    if [ ! -f "$COMBINED_SIM_PLIST" ] && [ -f "$DEVICE_PLIST" ]; then
        echo "Synthesizing simulator Info.plist for $FRAMEWORK..."
        cp "$DEVICE_PLIST" "$COMBINED_SIM_PLIST"
        /usr/libexec/PlistBuddy -c "Set :CFBundleSupportedPlatforms:0 iPhoneSimulator" "$COMBINED_SIM_PLIST"
        /usr/libexec/PlistBuddy -c "Set :DTPlatformName iphonesimulator" "$COMBINED_SIM_PLIST"
        DEVICE_SDK=$(/usr/libexec/PlistBuddy -c "Print :DTSDKName" "$COMBINED_SIM_PLIST")
        /usr/libexec/PlistBuddy -c "Set :DTSDKName ${DEVICE_SDK/iphoneos/iphonesimulator}" "$COMBINED_SIM_PLIST"
    fi

    # Verify the architectures in the combined binary
    echo "Verifying architectures in combined simulator binary:"
    lipo -info "$COMBINED_SIM_BINARY"
done

# Create XCFrameworks
echo "Creating XCFrameworks..."
mkdir -p build/ios/universal

# Create XCFramework for each framework
for FRAMEWORK in $FRAMEWORKS; do
    echo "Creating XCFramework for $FRAMEWORK..."

    # Extract the base name without the .framework extension
    FRAMEWORK_BASE=$(basename "$FRAMEWORK" .framework)

    # Remove existing XCFramework if it exists
    rm -rf "build/ios/universal/$FRAMEWORK_BASE.xcframework"

    # Create XCFramework with device and combined simulator slices
    xcodebuild -create-xcframework \
        -framework "build/ios/arm64/$FRAMEWORK" \
        -framework "build/ios/simulator-combined/$FRAMEWORK" \
        -output "build/ios/universal/$FRAMEWORK_BASE.xcframework"

    # Add flattened headers to each framework slice
    for SLICE_DIR in "build/ios/universal/$FRAMEWORK_BASE.xcframework"/*; do
        if [ -d "$SLICE_DIR" ]; then
            FRAMEWORK_DIR=$(find "$SLICE_DIR" -name "*.framework" -type d)
            if [ -n "$FRAMEWORK_DIR" ]; then
                HEADERS_DIR_TARGET="$FRAMEWORK_DIR/Headers"
                mkdir -p "$HEADERS_DIR_TARGET"

                # Copy appropriate headers based on framework name (flattened structure)
                if [[ "$FRAMEWORK_BASE" == "libEGL" ]]; then
                    cp -R angle/include/EGL/*.h "$HEADERS_DIR_TARGET/"
                    cp -R angle/include/KHR/*.h "$HEADERS_DIR_TARGET/"
                elif [[ "$FRAMEWORK_BASE" == "libGLESv2" ]]; then
                    cp -R angle/include/GLES2/*.h "$HEADERS_DIR_TARGET/"
                    cp -R angle/include/GLES3/*.h "$HEADERS_DIR_TARGET/"
                    cp -R angle/include/KHR/*.h "$HEADERS_DIR_TARGET/"
                fi

                echo "Added headers to $FRAMEWORK_DIR"
            fi
        fi
    done

    echo "Created XCFramework with headers: build/ios/universal/$FRAMEWORK_BASE.xcframework"
done

# Create a standard include directory structure alongside the XCFrameworks
echo "Creating standard include directory structure..."
mkdir -p build/ios/universal/include/EGL
mkdir -p build/ios/universal/include/GLES2
mkdir -p build/ios/universal/include/GLES3
mkdir -p build/ios/universal/include/KHR

# Copy headers to the standard include structure
cp -R angle/include/EGL/*.h build/ios/universal/include/EGL/
cp -R angle/include/GLES2/*.h build/ios/universal/include/GLES2/
cp -R angle/include/GLES3/*.h build/ios/universal/include/GLES3/
cp -R angle/include/KHR/*.h build/ios/universal/include/KHR/

# Create a README in the include directory explaining usage
cat > "build/ios/universal/include/README.md" << EOL
# ANGLE Headers for iOS

These headers are organized in a standard structure for cross-platform consistency.

## Usage in Cross-Platform Code

For cross-platform code that needs to compile on multiple platforms (Windows, macOS, iOS),
include these headers as follows:

\`\`\`c
#include <EGL/egl.h>
#include <GLES2/gl2.h>
\`\`\`

## Integration with Xcode

1. Add this include directory to your Header Search Paths
2. Link against the ANGLE XCFrameworks (libEGL.xcframework and libGLESv2.xcframework)

## Alternative Usage for iOS-only Code

For iOS-only code, you can also use the framework-style includes:

\`\`\`objc
#import <libEGL/egl.h>
#import <libGLESv2/gl2.h>
\`\`\`

Both approaches will work, but the first is recommended for cross-platform consistency.
EOL

echo "iOS builds complete! Frameworks are available in:"
echo "  - build/ios/arm64 (for iOS devices)"
echo "  - build/ios/simulator-arm64 (for ARM64 simulators)"
echo "  - build/ios/simulator-x86_64 (for x86_64 simulators)"
echo "  - build/ios/simulator-combined (combined simulators with both arm64 and x86_64)"
echo "  - build/ios/universal (XCFrameworks for all platforms)"
echo "Headers are available in two formats:"
echo "  - Standard include structure: build/ios/universal/include/"
echo "  - Framework-embedded headers: inside each XCFramework"