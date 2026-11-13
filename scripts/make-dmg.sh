#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
app_bundle="$PWD/build/Build/Products/Release/Pisa.app"
[[ -d "$app_bundle" ]] || { print -u2 "Сначала соберите Pisa.app"; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Contents/Info.plist")
output="$PWD/build/Pisa-${version}-arm64.dmg"
# A unique mount point prevents an open installer image from affecting this build.
scratch=$(mktemp -d "$PWD/build/dmg.XXXXXX")
mount_path="$scratch/mounted"
mounted=0
cleanup() {
    if (( mounted )); then
        if ! hdiutil detach "$mount_path" -quiet; then
            print -u2 "Не удалось извлечь образ. Временная папка сохранена: $scratch"
            return 1
        fi
    fi
    rm -rf "$scratch"
}
trap cleanup EXIT
stage="$scratch/stage"
mkdir -p "$stage/.background" "$mount_path"
ditto "$app_bundle" "$stage/Pisa.app"
ln -s /Applications "$stage/Applications"
swift scripts/make-dmg-background.swift "$stage/.background/background" 600 330 160 440 200
hdiutil create -volname Pisa -srcfolder "$stage" -fs HFS+ -format UDRW -ov "$scratch/writable.dmg" >/dev/null
hdiutil attach "$scratch/writable.dmg" -mountpoint "$mount_path" -readwrite -noverify -noautoopen -nobrowse >/dev/null
mounted=1
# These tiny Python packages are build-only; they never enter the app or DMG.
# Writing the layout directly avoids Finder automation prompts and asynchronous saves.
tools="$PWD/build/dmg-tools"
if [[ ! -x "$tools/bin/python3" ]]; then python3 -m venv "$tools"; fi
if ! "$tools/bin/python3" -c 'import ds_store, mac_alias' >/dev/null 2>&1; then
    "$tools/bin/python3" -m pip --disable-pip-version-check install ds-store==1.3.1 mac-alias==2.2.2
fi
"$tools/bin/python3" scripts/make-ds-store.py "$mount_path"
[[ -f "$mount_path/.DS_Store" ]] || { print -u2 "Не удалось сохранить оформление установщика"; exit 1; }
swift scripts/make-icon.swift "$scratch/PisaVolume.iconset" Resources/BrandMark.json --volume
iconutil -c icns -o "$mount_path/.VolumeIcon.icns" "$scratch/PisaVolume.iconset"
SetFile -a C "$mount_path"
rm -rf "$mount_path/.fseventsd"
hdiutil detach "$mount_path" -quiet
mounted=0
hdiutil convert "$scratch/writable.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$output" >/dev/null
hdiutil verify "$output"
print "Готово: $output"
