Automatic merge of The412Banner/DroidDeck's `main`.

Both builds run on this pull request: the Android APK (which the iOS port does
not touch) and the unsigned iOS IPA.

What to check before merging:

- nothing under `app/`, `tools/` or `.github/workflows/build.yml` lost a change
  the port depends on;
- `ios/` still builds and `AppleDeckCore`'s tests still pass — upstream has no
  reason to break either, and CI says so rather than this note;
- the preference keys in `ios/Packages/AppleDeckCore/Sources/AppleDeckCore/Prefs.swift`
  still match `session/SessionPrefs.kt`. That last one is the only place this
  port can be silently wrong: a key upstream renames is a setting that stops
  applying, with nothing failing and no error anywhere.