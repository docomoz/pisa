#!/bin/zsh
set -euo pipefail

if [[ $# != 2 || ! -f "$1" || ! -f "$2" ]]; then
    print -u2 "Использование: $0 <Pisa-версия-arm64.dmg> <заметки-к-релизу.md>"
    exit 1
fi

dmg="${1:A}"
notes="${2:A}"
cd "$(dirname "$0")/.."

sparkle="$PWD/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$sparkle/generate_appcast" ]]; then
    print -u2 "Сначала запустите ./scripts/build.sh"
    exit 1
fi

scratch=$(mktemp -d)
mount_path="$scratch/mounted"
mounted=0
cleanup() {
    if (( mounted )); then
        hdiutil detach "$mount_path" -quiet || return
    fi
    rm -rf "$scratch"
}
trap cleanup EXIT

mkdir "$mount_path" "$scratch/assets"
staged_dmg="$scratch/assets/${dmg:t}"
cp "$dmg" "$staged_dmg"
hdiutil attach "$staged_dmg" -mountpoint "$mount_path" -readonly -nobrowse -noautoopen >/dev/null
mounted=1
app="$mount_path/Pisa.app"
plist="$app/Contents/Info.plist"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' || ! "$build_number" =~ '^[0-9]+$' ||
      "${dmg:t}" != "Pisa-$version-arm64.dmg" || "$(lipo -archs "$app/Contents/MacOS/Pisa")" != arm64 ]]; then
    print -u2 "Имя образа, версия или архитектура приложения не подходят для релиза"
    exit 1
fi
if [[ "$("$sparkle/generate_keys" --account pisya -p)" != "$public_key" ]]; then
    print -u2 "Ключ Sparkle в связке ключей не совпадает с открытым ключом в образе"
    exit 1
fi
hdiutil detach "$mount_path" -quiet
mounted=0

asset_url="https://github.com/docomoz/pisa/releases/download/v$version/"
cp "$notes" "${staged_dmg:r}.md"
"$sparkle/generate_appcast" --account pisya --maximum-deltas 0 --embed-release-notes \
    --link https://github.com/docomoz/pisa/releases/latest --download-url-prefix "$asset_url" "$scratch/assets"
feed="$scratch/assets/pisa-updates.xml"
"$sparkle/sign_update" --account pisya --verify "$feed"

# Installed copies with the previous bundle ID need a manual migration.
for legacy_name in appcast.xml pisa-appcast.xml; do
legacy_feed="$scratch/$legacy_name"
cat > "$legacy_feed" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Pisa</title>
    <link>https://getpisa.app/</link>
    <description>Переход на Pisa</description>
    <item>
      <title>Pisa $version</title>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <link>https://getpisa.app/migration</link>
      <description><![CDATA[<p>Вышла Pisa с исправленным системным идентификатором. Установите новую версию вручную и перенесите библиотеку по инструкции.</p>]]></description>
    </item>
  </channel>
</rss>
EOF
"$sparkle/sign_update" --account pisya "$legacy_feed"
"$sparkle/sign_update" --account pisya --verify "$legacy_feed"
done


sha256=$(shasum -a 256 "$staged_dmg" | cut -d ' ' -f 1)
sed -e "s/@VERSION@/$version/g" -e "s/@SHA256@/$sha256/g" \
    packaging/homebrew/pisa.rb.in > "$scratch/pisa.rb"
ruby -c "$scratch/pisa.rb"

out="$PWD/build/release-v$version"
mkdir -p "$out"
cp "$staged_dmg" "$feed" "$scratch/appcast.xml" "$scratch/pisa-appcast.xml" "$scratch/pisa.rb" "$out/"
printf '%s  %s\n' "$sha256" "${dmg:t}" > "$out/SHA256SUMS"
print "Готово: $out"
