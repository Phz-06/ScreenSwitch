#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="ScreenSwitch.app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
xcrun clang -arch arm64 -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -Os \
  ScreenSwitch.m Relay.m -framework AppKit -framework Carbon -framework IOKit \
  -o "$app/Contents/MacOS/ScreenSwitch"
codesign --force --sign - "$app"
