# CubeChat patches to photo_manager 3.10.0

## No private `PHAsset.filename` (2026-09-24)

App Review rejected build 1080 under guideline 2.5.1 for referencing
`PHAsset.filename`, a private key. Upstream `-[PHAsset title]`
(`darwin/.../core/PHAsset+PM_COMMON.m`) read it by KVO —
`[self valueForKey:@"filename"]` — and only fell back to the public
`PHAssetResource.originalFilename` when that threw. The fallback is now the only
path; the KVO read is gone.

The same file is mirrored in `ios/` and `macos/` (upstream keeps them as
symlinks to `darwin/`, which is what `sharedDarwinSource: true` builds from);
all three copies carry the patch so a later tree switch can't bring it back.

Removed from the vendored copy, unused by the app: `example/`, `test/`.

## Upgrading

Take the new version from the pub cache, reapply the change above, and check:

```bash
grep -rn 'valueForKey:@"filename"' third_party/photo_manager
```

must print nothing.
