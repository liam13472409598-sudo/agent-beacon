#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
output_dir="${AGENT_BEACON_OUTPUT_DIR:-$project_dir/dist}"
app_dir="$output_dir/AgentBeacon.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swiftc -parse-as-library -O -target arm64-apple-macosx14.0 -framework AppKit -framework SwiftUI "$project_dir/AgentBeacon.swift" -o "$app_dir/Contents/MacOS/AgentBeacon"
cp "$project_dir/agent_beacon_hook.py" "$project_dir/install_hooks.py" "$app_dir/Contents/Resources/"
cp "$project_dir/assets/AppIcon.icns" "$app_dir/Contents/Resources/"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Agent Beacon</string>
<key>CFBundleDisplayName</key><string>Agent 哨站</string>
<key>CFBundleIdentifier</key><string>local.agentbeacon.app</string>
<key>CFBundleExecutable</key><string>AgentBeacon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleShortVersionString</key><string>0.10.0</string>
<key>CFBundleVersion</key><string>10</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
