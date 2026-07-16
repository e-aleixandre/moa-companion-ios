#!/bin/sh
# Diagnóstico de firma para Xcode Cloud (ITMS-90035).
# Vuelca identidad de firma, provisioning profile y entitlements del archive
# y de cada variante firmada que Xcode Cloud exporta.
set -u

inspect_app() {
    label="$1"
    app="$2"
    echo ""
    echo "########## $label"
    if [ ! -d "$app" ]; then
        echo "(no existe: $app)"
        return
    fi
    echo "=== codesign -dvvv"
    codesign -dvvv "$app" 2>&1 || true
    echo "=== embedded.mobileprovision"
    if [ -f "$app/embedded.mobileprovision" ]; then
        security cms -D -i "$app/embedded.mobileprovision" 2>/dev/null > /tmp/profile.plist || true
        for key in Name TeamName "Entitlements:application-identifier" "Entitlements:get-task-allow" ProvisionsAllDevices ExpirationDate; do
            printf "%s = " "$key"
            /usr/libexec/PlistBuddy -c "Print :$key" /tmp/profile.plist 2>/dev/null || echo "(ausente)"
        done
    else
        echo "SIN embedded.mobileprovision"
    fi
    echo "=== entitlements del binario"
    codesign -d --entitlements - "$app" 2>&1 || true
}

if [ -n "${CI_ARCHIVE_PATH:-}" ]; then
    inspect_app "ARCHIVE (pre-export)" "$CI_ARCHIVE_PATH/Products/Applications/Moa Pulse.app"
fi
[ -n "${CI_APP_STORE_SIGNED_APP_PATH:-}" ] && inspect_app "APP-STORE SIGNED" "$CI_APP_STORE_SIGNED_APP_PATH/Moa Pulse.app"
[ -n "${CI_DEVELOPMENT_SIGNED_APP_PATH:-}" ] && inspect_app "DEVELOPMENT SIGNED" "$CI_DEVELOPMENT_SIGNED_APP_PATH/Moa Pulse.app"
[ -n "${CI_AD_HOC_SIGNED_APP_PATH:-}" ] && inspect_app "AD-HOC SIGNED" "$CI_AD_HOC_SIGNED_APP_PATH/Moa Pulse.app"

echo ""
echo "=== env CI_* relevantes"
env | grep -E "^CI_(WORKFLOW|XCODEBUILD_ACTION|ARCHIVE_PATH|APP_STORE|DEVELOPMENT_SIGNED|AD_HOC)" | sort || true
exit 0
