#!/bin/sh
# Build Broadside.pdx (and optionally open it in the Playdate Simulator).
#   ./build.sh        build
#   ./build.sh run    build and launch in the Simulator
set -e
cd "$(dirname "$0")"
SDK="${PLAYDATE_SDK_PATH:-$HOME/Developer/PlaydateSDK}"

# The small UI font ships with the Playdate SDK (it's Panic's, so it isn't
# checked into this repo). Copy it in from the SDK before compiling.
FONT_SRC="$SDK/Resources/Fonts/Roobert"
mkdir -p source/fonts
for f in Roobert-10-Bold.fnt Roobert-10-Bold-table-12-14.png; do
	[ -f "source/fonts/$f" ] || cp "$FONT_SRC/$f" source/fonts/
done

"$SDK/bin/pdc" source Broadside.pdx
echo "Built Broadside.pdx"
[ "$1" = "run" ] && open -a "$SDK/bin/Playdate Simulator.app" Broadside.pdx
exit 0
