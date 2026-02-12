#!/bin/bash
# Build containers with proper error handling

set -e

CONTAINER_NAME="$1"
DEF_FILE="$2"

if [ -z "$CONTAINER_NAME" ] || [ -z "$DEF_FILE" ]; then
    echo "Usage: $0 <container.sif> <definition.def>"
    exit 1
fi

echo "Building $CONTAINER_NAME from $DEF_FILE"

# Try different build methods in order of preference
build_container() {
    local sif=$1
    local def=$2
    
    # Method 1: Regular build (no special privileges needed)
    echo "Attempt 1: Regular build (no fakeroot)..."
    if apptainer build "$sif" "$def" 2>&1; then
        echo "✓ Success with regular build"
        return 0
    fi
    
    # Method 2: With fakeroot
    echo "Attempt 2: Build with --fakeroot..."
    if apptainer build --fakeroot "$sif" "$def" 2>&1; then
        echo "✓ Success with --fakeroot"
        return 0
    fi
    
    # Method 3: With fakeroot but ignore fakeroot command inside
    echo "Attempt 3: Build with --fakeroot --ignore-fakeroot-command..."
    if apptainer build --fakeroot --ignore-fakeroot-command "$sif" "$def" 2>&1; then
        echo "✓ Success with --fakeroot --ignore-fakeroot-command"
        return 0
    fi
    
    # Method 4: Try with sudo (if available)
    if command -v sudo >/dev/null 2>&1; then
        echo "Attempt 4: Build with sudo..."
        if sudo apptainer build "$sif" "$def" 2>&1; then
            echo "✓ Success with sudo"
            return 0
        fi
    fi
    
    echo "✗ All build methods failed"
    return 1
}

if build_container "$CONTAINER_NAME" "$DEF_FILE"; then
    echo ""
    echo "========================================" 
    echo "Build successful!"
    ls -lh "$CONTAINER_NAME"
    echo "========================================"
    exit 0
else
    echo ""
    echo "========================================" 
    echo "Build failed!"
    echo "========================================"
    echo ""
    echo "Try manually with:"
    echo "  sudo apptainer build $CONTAINER_NAME $DEF_FILE"
    echo ""
    echo "Or use remote build:"
    echo "  apptainer build --remote $CONTAINER_NAME $DEF_FILE"
    exit 1
fi
