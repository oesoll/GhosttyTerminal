#!/bin/sh
# libghostty(GhosttyKit.xcframework)를 고정된 Ghostty 커밋에서 빌드해 Frameworks/에 둔다.
# 터미널은 이 정적 라이브러리가 그린다(웹뷰 없음). 산출물(140MB 남짓)은 저장소에 넣지 않는다.
# 필요한 것: zig 0.17(brew install zig), Xcode의 Metal 도구.
set -eu
GHOSTTY_COMMIT=ae0dc1b
SRC="${GHOSTTY_SRC:-$HOME/.cache/sm-ghostty/ghostty}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$SRC/.git" ]; then
  git clone https://github.com/ghostty-org/ghostty "$SRC"
fi
cd "$SRC"
if ! git cat-file -e "$GHOSTTY_COMMIT^{commit}" 2>/dev/null; then
  git fetch --depth 1 origin "$GHOSTTY_COMMIT" || git fetch --unshallow origin
fi
git checkout -q "$GHOSTTY_COMMIT"
git checkout -q -- .
for patch in "$ROOT"/scripts/ghostty-patches/*.patch; do
  git apply "$patch"
done
zig build -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast
rm -rf "$ROOT/Frameworks/GhosttyKit.xcframework"
mkdir -p "$ROOT/Frameworks"
cp -R macos/GhosttyKit.xcframework "$ROOT/Frameworks/"
echo "GhosttyKit.xcframework → $ROOT/Frameworks (ghostty $GHOSTTY_COMMIT)"
