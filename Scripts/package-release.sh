#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
app_path="$project_root/dist/FanFic to Audio.app"
/usr/bin/codesign --verify --deep --strict "$app_path"
release_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_path/Contents/Info.plist")
release_arch=$(uname -m)
release_name="FanFic-to-Audio-${release_version}-macOS-${release_arch}"
zip_path="$project_root/dist/$release_name.zip"
dmg_path="$project_root/dist/$release_name.dmg"
if [[ -e "$zip_path" || -e "$dmg_path" ]]; then
    print -u2 'Release assets already exist. Preserve them or choose a new version before packaging.'
    exit 1
fi
# A profile stores notarization credentials in Keychain, separate from the token.
# Leave NOTARY_PROFILE unset for explicitly unnotarized development packaging.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    signed_info=$(/usr/bin/codesign -dvv "$app_path" 2>&1)
    if [[ "$signed_info" != *"Authority=Developer ID Application:"* || "$signed_info" != *"runtime"* ]]; then
        print -u2 'Notarization requires Developer ID signing with hardened runtime.'
        exit 1
    fi
    submission_dir=$(mktemp -d "$project_root/dist/.notary.XXXXXX")
    trap 'rm -rf "$submission_dir"' EXIT
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_dir/submission.zip"
    /usr/bin/xcrun notarytool submit "$submission_dir/submission.zip" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 20m --output-format json > "$submission_dir/result.json"
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted", "Apple did not accept the notarization"' "$submission_dir/result.json"
    /usr/bin/xcrun stapler staple "$app_path"
    /usr/bin/xcrun stapler validate "$app_path"
    /usr/sbin/spctl --assess --type execute --verbose "$app_path"
fi
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
image_stage=$(mktemp -d "$project_root/dist/.dmg.XXXXXX")
trap 'rm -rf "$image_stage" "${submission_dir:-}"' EXIT
/usr/bin/ditto "$app_path" "$image_stage/FanFic to Audio.app"
ln -s /Applications "$image_stage/Applications"
/usr/bin/hdiutil create -volname 'FanFic to Audio' -srcfolder "$image_stage" -ov -format UDZO "$dmg_path"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    /usr/bin/codesign --sign "$SIGNING_IDENTITY" --timestamp "$dmg_path"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    /usr/bin/xcrun notarytool submit "$dmg_path" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 20m --output-format json > "$image_stage/notary.json"
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted", "Apple did not accept the DMG"' "$image_stage/notary.json"
    /usr/bin/xcrun stapler staple "$dmg_path"
    /usr/bin/xcrun stapler validate "$dmg_path"
fi
(cd "$project_root/dist" && shasum -a 256 "$release_name.zip" "$release_name.dmg" > "$release_name.sha256")
print "Packaged: $zip_path"
print "Packaged: $dmg_path"
