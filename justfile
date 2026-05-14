# ─── DontBlastMySound ─────────────────────────────────────────────────────────

tuist := "tuist"
scheme := "DontBlastMySound"

default: generate

# Generate Xcode project from Tuist manifests
generate:
    {{tuist}} generate --no-open

# Build the app (pass "release" to build in release mode)
build release="debug":
    {{tuist}} xcodebuild -workspace {{scheme}}.xcworkspace -scheme {{scheme}} {{ if release == "release" { "-configuration Release" } else { "" } }} build

# Build and launch the app
run:
    {{tuist}} run {{scheme}}

