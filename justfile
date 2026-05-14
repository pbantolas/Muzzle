# ─── Muzzle ───────────────────────────────────────────────────────────────────

tuist := "tuist"
scheme := "Muzzle"

default: generate

# Generate Xcode project from Tuist manifests
generate:
    {{tuist}} generate --no-open

# Build the app (pass "release" to build in release mode)
build release="debug":
    {{tuist}} xcodebuild -workspace {{scheme}}.xcworkspace -scheme {{scheme}} {{ if release == "release" { "-configuration Release" } else { "" } }} build

# Run unit tests
test:
    {{tuist}} xcodebuild -workspace {{scheme}}.xcworkspace -scheme {{scheme}} test

# Build and launch the app
run:
    {{tuist}} run {{scheme}}
