#!/bin/sh
# Diagnóstico de firma para Xcode Cloud (ITMS-90035).
# Vuelca la identidad de firma y el provisioning profile del .app archivado.
set -u

if [ -z "${CI_ARCHIVE_PATH:-}" ]; then
    echo "No CI_ARCHIVE_PATH (build sin archive); nada que inspeccionar."
    exit 0
fi

APP="$CI_ARCHIVE_PATH/Products/Applications/Moa Pulse.app"
echo "=== Archive: $CI_ARCHIVE_PATH"
ls -la "$CI_ARCHIVE_PATH/Products/Applications/" || true

echo "=== codesign -dvvv"
codesign -dvvv "$APP" 2>&1 || true

echo "=== codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 || true

echo "=== embedded.mobileprovision"
if [ -f "$APP/embedded.mobileprovision" ]; then
    security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -p - 2>/dev/null | grep -E "Name|TeamName|application-identifier|get-task-allow|ProvisionsAllDevices|ProvisionedDevices|ExpirationDate|aps-environment" || true
else
    echo "SIN embedded.mobileprovision"
fi

echo "=== entitlements del binario"
codesign -d --entitlements :- "$APP" 2>&1 || true
