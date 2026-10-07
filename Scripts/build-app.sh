#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
"$project_root/Scripts/swift.sh" build -c release --product EPUBToMP3
mkdir -p "$project_root/dist"
stage_path="$(mktemp -d "$project_root/dist/.app-build.XXXXXX")"
trap 'rm -rf "$stage_path"' EXIT
app_path="$stage_path/EPUB to MP3.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
binary_dir=$("$project_root/Scripts/swift.sh" build -c release --show-bin-path)
cp "$binary_dir/EPUBToMP3" "$app_path/Contents/MacOS/EPUBToMP3"
cp "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
if [[ -f "$project_root/Resources/AppIcon.icns" ]]; then
    cp "$project_root/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
fi
/usr/bin/codesign --force --sign - "$app_path"
final_path="$project_root/dist/EPUB to MP3.app"
# Move the complete bundle into place without modifying a running executable.
if [[ -d "$final_path" ]]; then
    backup_dir="$project_root/dist/Previous Builds"
    mkdir -p "$backup_dir"
    backup_path="$backup_dir/EPUB to MP3-$(date +%Y%m%d-%H%M%S)-$(uuidgen).app"
    mv "$final_path" "$backup_path"
fi
if ! mv "$app_path" "$final_path"; then
    if [[ -n "${backup_path:-}" ]]; then mv "$backup_path" "$final_path"; fi
    exit 1
fi
print "Built: $final_path"
