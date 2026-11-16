#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
OUT="${1:-$PWD/dist}"
if [[ "${BUILD_UNSIGNED:-0}" == 1 ]]; then
    SIGN_IDENTITY="-"
    TEAM_ID="PREVIEWONLY"
else
    : "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your own Apple Development signing identity}"
    : "${TEAM_ID:?Set TEAM_ID to your own Apple Developer team ID}"
fi
GROUP_ID="$TEAM_ID.local.bandwagon.monitor"
mkdir -p "$OUT/.build"
APP="$OUT/搬瓦工监控.app"
EXT="$APP/Contents/PlugIns/BandwagonWidgets.appex"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -O -module-cache-path "$OUT/.build/module-cache" -framework AppKit -framework SwiftUI -framework Security -framework ServiceManagement -framework Charts -framework WidgetKit Sources/*.swift Shared/*.swift -o "$APP/Contents/MacOS/BandwagonMonitor"
if [[ "${BUILD_UNSIGNED:-0}" != 1 ]]; then
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -application-extension -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -u -Xlinker _main -O -module-cache-path "$OUT/.build/module-cache" -framework SwiftUI -framework Charts -framework WidgetKit Shared/*.swift Widget/BandwagonWidgets.swift -o "$EXT/Contents/MacOS/BandwagonWidgets"
fi
python3 - "$APP" "$GROUP_ID" "$OUT/.build" "${BUILD_UNSIGNED:-0}" <<'PY'
import plistlib,sys,shutil
from pathlib import Path
app=Path(sys.argv[1]); group=sys.argv[2]
agents = app/'Contents/Library/LaunchAgents'
agents.mkdir(parents=True,exist_ok=True)
(agents/'local.bandwagon.monitor.autostart.plist').write_bytes(plistlib.dumps({'Label':'local.bandwagon.monitor.autostart','BundleProgram':'Contents/MacOS/BandwagonMonitor','ProgramArguments':['BandwagonMonitor','--background'],'RunAtLoad':True,'LimitLoadToSessionType':'Aqua','ProcessType':'Interactive','AssociatedBundleIdentifiers':['local.bandwagon.monitor']}))
info={'CFBundleExecutable':'BandwagonMonitor','CFBundleIdentifier':'local.bandwagon.monitor','CFBundleName':'搬瓦工监控','CFBundleDisplayName':'搬瓦工监控','CFBundleVersion':'10','CFBundleShortVersionString':'1.3.0','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'14.0','LSUIElement':True,'NSHighResolutionCapable':True,'CFBundleIconFile':'AppIcon','MonitorAppGroup':group,'CFBundleURLTypes':[{'CFBundleURLName':'Monitor widget links','CFBundleURLSchemes':['bandwagon-monitor']} ]}
ext={'CFBundleExecutable':'BandwagonWidgets','CFBundleIdentifier':'local.bandwagon.monitor.widgets','CFBundleName':'搬瓦工监控','CFBundleDisplayName':'搬瓦工监控','CFBundleVersion':'10','CFBundleShortVersionString':'1.3.0','CFBundlePackageType':'XPC!','CFBundleSupportedPlatforms':['MacOSX'],'LSMinimumSystemVersion':'14.0','MonitorAppGroup':group,'NSExtension':{'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}}
if sys.argv[4] == '1':
 info['CFBundleIdentifier']='local.bandwagon.monitor.preview'
 info['CFBundleName']='搬瓦工监控演示'
 info['CFBundleDisplayName']='搬瓦工监控演示'
 info['PreviewOnly']=True
 info.pop('CFBundleURLTypes',None)
 ext['CFBundleIdentifier']='local.bandwagon.monitor.preview.widgets'
for path, value in [(app/'Contents/Info.plist',info),(app/'Contents/PlugIns/BandwagonWidgets.appex/Contents/Info.plist',ext)]:
 path.write_bytes(plistlib.dumps(value))
# Screenshot hosts must not embed discoverable WidgetKit extensions.
if sys.argv[4] == '1':
 shutil.rmtree(app/'Contents/PlugIns',ignore_errors=True)
(Path(sys.argv[3])/'host.entitlements').write_bytes(plistlib.dumps({'com.apple.security.application-groups':[group]}))
(Path(sys.argv[3])/'widget.entitlements').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.application-groups':[group]}))
PY
cp AppIcon.icns "$APP/Contents/Resources/"
if [[ "${BUILD_UNSIGNED:-0}" != 1 ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --entitlements "$OUT/.build/widget.entitlements" "$EXT"
fi
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$OUT/.build/host.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/BandwagonMonitor" --self-test
if [[ "${BUILD_UNSIGNED:-0}" != 1 ]]; then
    "$APP/Contents/MacOS/BandwagonMonitor" --widget-check
fi
