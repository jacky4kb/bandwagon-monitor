#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD_DIR="${1:-$ROOT/dist/screenshots-build}"
mkdir -p "$BUILD_DIR/app-previews" "$BUILD_DIR/widget-previews" "$ROOT/docs/screenshots"
BUILD_UNSIGNED=1 "$ROOT/build.sh" "$BUILD_DIR"
"$BUILD_DIR/搬瓦工监控.app/Contents/MacOS/BandwagonMonitor" --preview "$BUILD_DIR/app-previews"
swiftc -D WIDGET_PREVIEW -swift-version 5 -target arm64-apple-macosx14.0 \
  -module-cache-path "$BUILD_DIR/.build/module-cache" \
  -framework SwiftUI -framework Charts -framework WidgetKit -framework AppKit \
  "$ROOT"/Shared/*.swift "$ROOT/Widget/BandwagonWidgets.swift" "$ROOT/Widget/Preview.swift" \
  -o "$BUILD_DIR/widget-preview"
"$BUILD_DIR/widget-preview" "$BUILD_DIR/widget-previews"
cp "$BUILD_DIR/app-previews/preview-0.png" "$ROOT/docs/screenshots/overview.png"
cp "$BUILD_DIR/app-previews/preview-1.png" "$ROOT/docs/screenshots/resources.png"
cp "$BUILD_DIR/app-previews/preview-2.png" "$ROOT/docs/screenshots/network.png"
cp "$BUILD_DIR/app-previews/preview-3.png" "$ROOT/docs/screenshots/history.png"
cp "$BUILD_DIR/app-previews/preview-7.png" "$ROOT/docs/screenshots/mini-window.png"
cp "$BUILD_DIR/app-previews/preview-9.png" "$ROOT/docs/screenshots/widget-guide.png"
for i in {0..12}; do
  cp "$BUILD_DIR/widget-previews/widget-$i.png" "$ROOT/docs/screenshots/widget-$i.png"
done
python3 "$ROOT/scripts/strip-png-metadata.py" "$ROOT/docs/screenshots"
python3 "$ROOT/scripts/check-public-files.py"
