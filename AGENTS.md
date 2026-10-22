# Local features and releases

- Personal features live only in ignored `Sources/*/LocalFeatures/` and `Tests/*/LocalFeatures/` directories. Their docs and screenshots live in ignored `docs/local-features/` and `docs/images/local-features/` directories.
- Do not force-add those paths, copy their content into tracked files, or include their functionality, account identifiers, screenshots, or descriptions in commits, release notes, source archives, or published assets.
- Preserve ignored personal sources during cleanup and resets; never remove them with an ignored-file cleanup operation.
- Public builds are the default. `./scripts/package-release.sh` must always force public mode and verify that its app contains no personal feature implementation before packaging.
- Local installation uses `./scripts/build-app.sh release local`; preserve the user's locally installed personal functionality when updating their app. Public artifacts must use a separate output directory and must not overwrite the local installed app.
- After every completed application development change, run the relevant checks, build with `./scripts/build-app.sh release local`, and install `build/local/Yukino Tools.app` to `/Applications/Yukino Tools.app` before handing the work back. This is the user's standing installation preference; do not ask again for routine updates. Back up the existing app, preserve personal functionality and user settings, and verify the installed signature and binary match the local build. Documentation-only changes do not require rebuilding or reinstalling.
- Run relevant public and local checks after changing build boundaries. Follow `docs/local-builds.md` for the two modes. The shared Xcode project must not reference ignored local sources.
