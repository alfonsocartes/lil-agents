# Contributing

PRs against `main`. Issues welcome. Conventional commits are welcome.

## macOS (`lil agents`)

```bash
scripts/build-app.sh          # release build → dist/lil agents.app
swift test
```

`scripts/build-app.sh` also accepts `debug`.

## iOS (`lil usage`)

Open `iOS/LilUsage.xcodeproj` in Xcode 26+ (iOS 18+).

If you change targets, regenerate the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `iOS/project.yml`:

```bash
cd iOS && xcodegen
```

Forkers must replace `DEVELOPMENT_TEAM` (currently `S74M2P6469` in `iOS/project.yml` and `iOS/LilUsage.xcodeproj/project.pbxproj`). App Group `group.com.wandity.lilagents` and the Keychain access group (`$(AppIdentifierPrefix)group.com.wandity.lilagents`) must match across the app, the widget, and `iOS/project.yml`.

## Don't commit

- `xcuserdata/`
- `.DS_Store`
- `dist/`
- `.build/`
