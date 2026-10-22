# Public builds and local features

The shared project and normal SwiftPM builds contain public functionality only. Optional personal code is stored in ignored `LocalFeatures` subdirectories under each source and test target; its docs and screenshots are ignored too. These files are never part of Git source archives or release notes.

```sh
# Public app (default); output: build/public/Yukino Tools.app
./scripts/build-app.sh release

# Personal app; output: build/local/Yukino Tools.app
./scripts/build-app.sh release local

# Test each mode
./scripts/test.sh
./scripts/test.sh local

# Public artifacts only; local environment settings cannot enable personal code
./scripts/package-release.sh
```

The package enables private code only when `YUKINO_LOCAL_FEATURES=1` and `YUKINO_PUBLIC_RELEASE` is not `1`. Scripts set both variables explicitly, and keep public and local build caches and app outputs separate. A personal build needs the ignored source files on this computer; cloning the public repository does not include them.

The shared Xcode project always excludes ignored local sources, including when regenerated. Use the explicit SwiftPM local build for personal functionality. Never force-add ignored files or generate releases from a local app bundle. Public packaging verifies its app before creating ZIP and DMG files, and does not replace the local app installed in Applications.
