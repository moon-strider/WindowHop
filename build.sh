#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ ! -f Resources/SigningCertificate.cer ]]; then
    print -u2 'Сначала выполните ./setup-signing.rb для создания постоянной подписи.'
    exit 1
fi
signingFingerprint=$(/usr/bin/openssl x509 -inform DER -in Resources/SigningCertificate.cer -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//;s/://g')
mkdir -p build/WindowHop.app/Contents/MacOS build/WindowHop.app/Contents/Resources
xcrun swiftc -swift-version 5 -module-cache-path build/ModuleCache -O -target "$(uname -m)-apple-macosx14.0" Sources/*.swift -o build/WindowHop.app/Contents/MacOS/WindowHop -framework Carbon -framework AppKit -framework SwiftUI -framework ScreenCaptureKit -framework ApplicationServices -framework ServiceManagement
cp Resources/Info.plist build/WindowHop.app/Contents/Info.plist
codesign --force --sign "$signingFingerprint" --keychain "$HOME/Library/Keychains/login.keychain-db" --timestamp=none --identifier local.windowhop.app --requirements "=designated => identifier \"local.windowhop.app\" and certificate leaf = H\"$signingFingerprint\"" build/WindowHop.app
codesign --verify --strict build/WindowHop.app
printf '%s\n' "$PWD/build/WindowHop.app"
