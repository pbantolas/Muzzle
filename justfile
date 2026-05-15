# ─── Muzzle ───────────────────────────────────────────────────────────────────

tuist := "tuist"
scheme := "Muzzle"
release_dir := "build/release"
archive_path := release_dir + "/" + scheme + ".xcarchive"
export_path := release_dir + "/export"
app_path := export_path + "/" + scheme + ".app"
notary_zip_path := release_dir + "/" + scheme + "-" + `cat VERSION` + "-notary.zip"
zip_path := release_dir + "/" + scheme + "-" + `cat VERSION` + "-macOS.zip"

default: generate

# Print the current app version
version:
    @cat VERSION

# Verify that a Developer ID Application certificate is installed
check-signing:
    @test -n "${APPLE_TEAM_ID:-}" || (echo "Set APPLE_TEAM_ID to your Apple Developer Team ID." && exit 1)
    @security find-identity -v -p codesigning | grep "Developer ID Application" || (echo "Missing Developer ID Application signing identity for direct distribution." && exit 1)

# Generate Xcode project from Tuist manifests
generate:
    {{tuist}} generate --no-open

# Build the app (pass "release" to build in release mode)
build release="debug":
    {{tuist}} xcodebuild -workspace {{scheme}}.xcworkspace -scheme {{scheme}} {{ if release == "release" { "-configuration Release" } else { "" } }} build

# Archive a Developer ID release build for direct download
archive: check-signing generate
    mkdir -p {{release_dir}}
    rm -rf {{archive_path}}
    {{tuist}} xcodebuild -workspace {{scheme}}.xcworkspace -scheme {{scheme}} -configuration Release -archivePath {{archive_path}} DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" ENABLE_HARDENED_RUNTIME=YES -allowProvisioningUpdates archive

# Export the archived app using Developer ID distribution settings
export-developer-id: archive
    rm -rf {{export_path}}
    mkdir -p {{export_path}}
    xcodebuild -exportArchive -archivePath {{archive_path}} -exportPath {{export_path}} -exportOptionsPlist Config/ExportOptions.DeveloperID.plist -allowProvisioningUpdates DEVELOPMENT_TEAM="$APPLE_TEAM_ID"

# Create a notarization credential profile in Keychain
notary-profile profile="muzzle-notary":
    @test -n "${APPLE_ID:-}" || (echo "Set APPLE_ID to your Apple Developer account email." && exit 1)
    @test -n "${APPLE_TEAM_ID:-}" || (echo "Set APPLE_TEAM_ID to your Apple Developer Team ID." && exit 1)
    xcrun notarytool store-credentials {{profile}} --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID"

# Notarize and staple the exported app. Run `just notary-profile` once first.
notarize profile="muzzle-notary": export-developer-id
    rm -f {{notary_zip_path}}
    ditto -c -k --keepParent {{app_path}} {{notary_zip_path}}
    xcrun notarytool submit {{notary_zip_path}} --keychain-profile {{profile}} --wait
    xcrun stapler staple {{app_path}}
    xcrun stapler validate {{app_path}}

# Zip the notarized app for GitHub Releases
package-zip: notarize
    rm -f {{zip_path}}
    ditto -c -k --keepParent {{app_path}} {{zip_path}}
    codesign --verify --deep --strict --verbose=2 {{app_path}}
    spctl --assess --type execute --verbose=4 {{app_path}}
    @echo {{zip_path}}

# Build the notarized zip for a GitHub Release
release: package-zip

# Run unit tests
test:
    {{tuist}} xcodebuild -workspace {{scheme}}.xcworkspace -scheme {{scheme}} test

# Build and launch the app
run:
    {{tuist}} run {{scheme}}
