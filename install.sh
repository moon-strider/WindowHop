#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ ! -d build/WindowHop.app ]]; then
    print -u2 'Сначала выполните ./build.sh'
    exit 1
fi
if /usr/bin/pgrep -x WindowHop >/dev/null; then
    /usr/bin/osascript -e 'tell application id "local.windowhop.app" to quit'
    for attempt in {1..50}; do
        if ! /usr/bin/pgrep -x WindowHop >/dev/null; then break; fi
        sleep 0.1
    done
    if /usr/bin/pgrep -x WindowHop >/dev/null; then
        print -u2 'Не удалось завершить WindowHop; установка остановлена.'
        exit 1
    fi
fi
installedBundle="$HOME/Applications/WindowHop.app"
newRequirement=$(/usr/bin/codesign --display --requirements - build/WindowHop.app 2>&1 | /usr/bin/sed -n 's/^[# ]*designated => //p')
if [[ -z "$newRequirement" || "$newRequirement" != *"certificate leaf"* ]]; then
    print -u2 'Сборка не имеет постоянной подписи сертификатом. Установка остановлена.'
    exit 1
fi
permissionMigrationNeeded=false
if [[ -e "$installedBundle" ]]; then
    oldRequirement=$(/usr/bin/codesign --display --requirements - "$installedBundle" 2>&1 | /usr/bin/sed -n 's/^[# ]*designated => //p')
    if [[ "$oldRequirement" != "$newRequirement" ]]; then permissionMigrationNeeded=true; fi
fi
mkdir -p "$HOME/Applications"
if [[ -e "$installedBundle" ]]; then
    /usr/bin/osascript - "$installedBundle" <<'APPLESCRIPT'
on run arguments
    set targetItem to (POSIX file (item 1 of arguments)) as alias
    tell application "Finder" to delete targetItem
end run
APPLESCRIPT
fi
/usr/bin/ditto build/WindowHop.app "$installedBundle"
/usr/bin/osascript - "$PWD/build" <<'APPLESCRIPT'
on run arguments
    set targetItem to (POSIX file (item 1 of arguments)) as alias
    tell application "Finder" to delete targetItem
end run
APPLESCRIPT
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installedBundle"
if [[ "$permissionMigrationNeeded" == true ]]; then
    /usr/bin/tccutil reset Accessibility local.windowhop.app
    /usr/bin/tccutil reset ScreenCapture local.windowhop.app
    print 'Подпись приложения изменилась: выдайте разрешения один раз для постоянного сертификата.'
fi
/usr/bin/open "$installedBundle"
print "Установлено: $installedBundle"
