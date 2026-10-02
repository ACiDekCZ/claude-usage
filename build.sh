#!/bin/bash
set -e

echo "Building ClaudeUsage..."
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release \
    -destination 'generic/platform=macOS' build

# Find and copy the built app
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/ClaudeUsage-*/Build/Products/Release -name "ClaudeUsage.app" 2>/dev/null | head -1)

if [ -n "$APP_PATH" ]; then
    rm -rf ClaudeUsage.app
    cp -R "$APP_PATH" .
    echo "Build complete! App copied to: $(pwd)/ClaudeUsage.app"
    echo "To install, copy ClaudeUsage.app to /Applications"
else
    echo "Build failed - app not found"
    exit 1
fi
