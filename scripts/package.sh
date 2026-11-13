#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
app_bundle="$PWD/build/Build/Products/Release/Pisa.app"
mkdir -p "$app_bundle/Contents/Helpers" "$app_bundle/Contents/Resources/Licenses"
cp build/Build/Products/Release/pisa-mcp "$app_bundle/Contents/Helpers/"
python3 - <<'PY'
from pathlib import Path
import plistlib
import shutil

contents = Path('build/Build/Products/Release/Pisa.app/Contents')

# Sparkle loads its own localization table. Adapt the Russian update prompts
# to Pisa before signing the embedded framework.
strings = contents / 'Frameworks/Sparkle.framework/Resources/ru.lproj/Sparkle.strings'
with strings.open('rb') as source:
    translations = plistlib.load(source)
overrides = {
    '%@ %@ is currently the newest version available.':
        'В настоящий момент %1$@ %2$@ является новейшей версией',
    '%@ %@ is currently the newest version available.\n(You are currently running version %@.)':
        'В настоящий момент %1$@ %2$@ является новейшей версией\n(У вас установлена %3$@)',
    '%1$@ can’t be updated because it was opened from a read-only or a temporary location.':
        'Не удаётся обновить %1$@ с тома, предназначенного только для чтения',
    'An error occurred while parsing the update feed.':
        'Произошла ошибка при извлечении канала обновления',
    'Use Finder to copy %1$@ to the Applications folder, relaunch it from there, and try again.':
        'Переместите %1$@ в папку «Программы», перезапустите его оттуда и повторите попытку',
    '%@ %@ is now available—you have %@. Would you like to download it now?':
        '%1$@ %2$@ теперь доступна. У вас версия %3$@. Хотите загрузить её сейчас?',
    '%1$@ %2$@ has been downloaded and is ready to use! Would you like to install it and relaunch %1$@ now?':
        '%1$@ %2$@ загружена. Хотите установить её и перезапустить %1$@?',
}
for key, translation in overrides.items():
    if key not in translations:
        raise SystemExit(f'Missing Sparkle localization key: {key}')
    translations[key] = translation
with strings.open('wb') as target:
    plistlib.dump(translations, target, fmt=plistlib.FMT_BINARY)

out = contents / 'Resources/Licenses'
roots = [Path('Vendor/mlx-audio-swift'), Path('Vendor/Sherpa'), Path('Vendor/WebRTCAEC'), Path('Vendor/SpeexDSP')]
checkouts = Path('build/SourcePackages/checkouts')
if checkouts.exists(): roots += list(checkouts.iterdir())
roots.append(Path('build/SourcePackages/artifacts/sparkle/Sparkle'))
for root in roots:
    for pattern in ('LICENSE*', 'COPYING*', 'NOTICE*', 'PATENTS', 'AUTHORS', '*-LICENSE', '*-NOTICE', 'ONNX-RUNTIME-LICENSE'):
        for source in root.glob(pattern):
            if source.is_file(): shutil.copyfile(source, out / (root.name + '-' + source.name))
PY
# Local identity is optional and must never be committed (contains machine-specific paths).
if [[ -f .signing.env ]]; then source .signing.env; fi
sign_args=(--sign "${PISA_SIGNING_IDENTITY:--}")
if [[ -n "${PISA_SIGNING_KEYCHAIN:-}" ]]; then
    sign_args+=(--keychain "$PISA_SIGNING_KEYCHAIN")
fi
if [[ "${PISA_SIGNING_IDENTITY:--}" == "Developer ID Application:"* ]]; then
    sign_args+=(--options runtime --timestamp)
fi

# Sparkle's installer leaves the app sandbox to replace the installed bundle.
sparkle="$app_bundle/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force "${sign_args[@]}" "$sparkle/XPCServices/Installer.xpc"
codesign --force "${sign_args[@]}" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
codesign --force "${sign_args[@]}" "$sparkle/Autoupdate"
codesign --force "${sign_args[@]}" "$sparkle/Updater.app"
codesign --force "${sign_args[@]}" "$app_bundle/Contents/Frameworks/Sparkle.framework"

# Sign every bundled native component with the same optional release identity.
for library in "$app_bundle"/Contents/Frameworks/*.dylib(N); do
    codesign --force "${sign_args[@]}" "$library"
done
codesign --force "${sign_args[@]}" "$app_bundle/Contents/Helpers/pisa-mcp"
codesign --force "${sign_args[@]}" --entitlements Resources/Pisa.entitlements "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
