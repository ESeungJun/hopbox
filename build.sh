#!/bin/bash
# HOPBOX(택배상자) 빌드. Xcode 없이 Command Line Tools 만으로 .app 을 만든다.
#   ./build.sh          → build/택배상자.app
#   ./build.sh install  → ~/Applications 에 설치하고 실행
#   ./build.sh release  → 애플 칩·인텔 칩용 설치 파일(.dmg)을 build/release 에 만든다
#
# 릴리스 서명·공증은 환경 변수로 켠다. 없으면 임시 서명만 하고 공증은 건너뛴다.
#   SIGN_IDENTITY   예: "Developer ID Application: 이름 (팀ID)"
#   NOTARY_PROFILE  xcrun notarytool store-credentials 로 저장한 프로필 이름
set -euo pipefail
cd "$(dirname "$0")"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# $1: 아키텍처(arm64·x86_64), $2: 만들 .app 경로
make_app() {
    swift build -c release --arch "$1"
    local app="$2"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp ".build/$1-apple-macosx/release/Hopbox" "$app/Contents/MacOS/Hopbox"
    cp Resources/Info.plist "$app/Contents/Info.plist"
    cp Resources/AppIcon.icns Resources/box-closed.png Resources/box-open.png "$app/Contents/Resources/"
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        codesign --force --sign - "$app"
    else
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
    fi
}

# $1: .app 경로, $2: 만들 .dmg 경로. 열면 응용 프로그램 폴더로 끌어 넣는 창이 뜬다
make_dmg() {
    local stage
    stage=$(mktemp -d)
    cp -R "$1" "$stage/"
    ln -s /Applications "$stage/Applications"
    hdiutil create -quiet -volname "택배상자" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$2"
    rm -rf "$stage"
    if [[ "$SIGN_IDENTITY" != "-" ]]; then
        codesign --force --timestamp --sign "$SIGN_IDENTITY" "$2"
    fi
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$2" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$2"
    fi
}

if [[ "${1:-}" == "release" ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    OUT="build/release"
    rm -rf "$OUT"
    for pair in "arm64:apple-silicon" "x86_64:intel"; do
        arch="${pair%%:*}"; name="${pair##*:}"
        mkdir -p "$OUT/$name"
        make_app "$arch" "$OUT/$name/택배상자.app"
        make_dmg "$OUT/$name/택배상자.app" "$OUT/Hopbox-$VERSION-macOS-$name.dmg"
    done
    echo "릴리스 파일:"
    ls -1 "$OUT"/*.dmg
    exit 0
fi

APP="build/택배상자.app"
make_app "$(uname -m)" "$APP"
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
