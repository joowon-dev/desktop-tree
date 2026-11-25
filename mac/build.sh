#!/bin/bash
# macOS 앱을 만든다. Xcode 프로젝트 없이 swiftc 로 바로 컴파일하고 .app 을 손으로 조립한다.
#   mac/build.sh            → dist/mac/Desktop Tree.app
#   mac/build.sh --zip      → dist/DesktopTree-mac.zip 까지
#
# 게임 코드(src/)는 그대로 Resources/web 에 들어간다. 빌드 단계에서 변형하지 않는다.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
name="Desktop Tree"
out="$root/dist/mac"
appdir="$out/$name.app"

rm -rf "$appdir"
mkdir -p "$appdir/Contents/MacOS" "$appdir/Contents/Resources/web"

echo "› 컴파일"
swiftc -O -whole-module-optimization \
  -target arm64-apple-macos13 \
  -o "$appdir/Contents/MacOS/DesktopTree" \
  "$root/mac/Sources/main.swift"

# 인텔 맥에서도 돌도록 x86_64 로도 한 번 더 만들어 합친다.
if swiftc -O -target x86_64-apple-macos13 -o "$out/.intel" "$root/mac/Sources/main.swift" 2>/dev/null; then
  lipo -create "$appdir/Contents/MacOS/DesktopTree" "$out/.intel" -output "$appdir/Contents/MacOS/DesktopTree.universal"
  mv "$appdir/Contents/MacOS/DesktopTree.universal" "$appdir/Contents/MacOS/DesktopTree"
  rm -f "$out/.intel"
  echo "› 유니버설 (arm64 + x86_64)"
fi

echo "› 리소스"
cp "$root/mac/Info.plist" "$appdir/Contents/Info.plist"
cp -R "$root/src/game" "$root/src/render" "$root/src/renderer" "$appdir/Contents/Resources/web/"

# 아이콘: build/icon.png → icns (scripts/make-icons.sh 가 그린다)
if [ -f "$root/build/icon.png" ]; then
  iconset="$out/icon.iconset"  # iconutil 은 .iconset 로 끝나는 이름만 받는다
  rm -rf "$iconset" && mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$root/build/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$root/build/icon.png" \
      --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$appdir/Contents/Resources/icon.icns"
  rm -rf "$iconset"
fi
# 메뉴바 아이콘. 없으면 셸이 🎄 이모지로 대신한다.
[ -f "$root/build/tray.png" ] && cp "$root/build/tray.png" "$appdir/Contents/Resources/tray.png"

# 이 앱은 **손쉬운 사용 권한**을 받는다(남의 창을 닫고 키우려고). 그 권한은 서명에 묶인다 —
# 임시 서명이면 빌드할 때마다 권한이 풀려서 다시 허용해야 한다. 개발 인증서가 있으면 그걸로 서명한다.
#   TREE_SIGN="인증서 이름"  으로 고를 수 있고,  TREE_SIGN=-  이면 임시 서명.
identity="${TREE_SIGN:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
if [ -n "$identity" ] && [ "$identity" != "-" ] && codesign --force --deep --sign "$identity" "$appdir" 2>/dev/null; then
  echo "› 서명: $identity"
else
  codesign --force --deep --sign - "$appdir" 2>/dev/null && echo "› 임시 서명" || echo "› 서명 건너뜀"
fi

du -sh "$appdir" | awk '{print "› 앱 크기 " $1}'

if [ "${1:-}" = "--zip" ]; then
  mkdir -p "$root/dist"
  (cd "$out" && ditto -c -k --keepParent "$name.app" "$root/dist/DesktopTree-mac.zip")
  du -h "$root/dist/DesktopTree-mac.zip" | awk '{print "› zip " $1}'
fi
