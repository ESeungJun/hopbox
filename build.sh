#!/bin/bash
# HOPBOX(택배상자) 빌드. Xcode 없이 Command Line Tools 만으로 .app 을 만든다.
#   ./build.sh          → build/택배상자.app
#   ./build.sh install  → ~/Applications 에 설치하고 실행
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/택배상자.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Hopbox "$APP/Contents/MacOS/Hopbox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/box-closed.png Resources/box-open.png "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "빌드 완료: $APP"

if [[ "${1:-}" == "install" ]]; then
    DEST="$HOME/Applications/택배상자.app"
    pkill -x Hopbox 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "설치 후 실행: $DEST"
fi
