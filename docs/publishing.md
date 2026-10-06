# Publishing to pub.dev

Ordinary branch pushes run validation. Publishing runs only when a version tag is pushed. Pub.dev's GitHub authentication requires a tag-triggered workflow; see [Dart's automated publishing documentation](https://dart.dev/tools/pub/automated-publishing).

On 2026-10-06, pub.dev still lists webview 0.2.1 and interface 0.1.1. The publishing runs for `v0.4.0` and `platform_interface-v0.1.2` were cancelled. The existing `v0.4.0` tag contains webview version 0.3.0, so it also mismatches the release version. Existing tags are preserved.

The updated publishing workflow installs the temporary pub.dev authentication through `dart-lang/setup-dart`, pins the Flutter/Dart versions used for validation, and rejects tags that differ from the package version.

## One-time account configuration

In each package's **Admin → Automated publishing** settings, enable GitHub Actions with repository `devflier/flutter_chromium_webview` and the corresponding tag pattern:

| Package | Tag pattern |
| --- | --- |
| flutter_chromium_webview | `v{{version}}` |
| flutter_chromium_webview_platform_interface | `platform_interface-v{{version}}` |

These account settings cannot be verified through the public package API. If an environment is required in those settings, the publishing job must also declare the same GitHub environment.

## Interface 0.1.4 release recovery

The existing `platform_interface-v0.1.3` tag points to commit `bc327be`, where the interface version is still 0.1.2 and the publishing workflow lacks authentication setup. Preserve that tag. Prepare interface **0.1.4** from the corrected workflow instead.

The main **0.3.1** publishing run succeeded on 2026-10-06, and its version endpoint confirms publication. Its `^0.1.3` dependency accepts interface 0.1.4; no main-package version bump or repeat publication is required.

Release the prepared interface version in this order:

1. Commit the interface version/changelog and these release notes, then push that commit.
2. Create `platform_interface-v0.1.4` on that commit and push the individual tag. Check the tag's pubspec version before pushing.
3. Confirm the interface publishing run succeeds and `https://pub.dev/api/packages/flutter_chromium_webview_platform_interface/versions/0.1.4` exists.
4. Verify a clean consumer can resolve main package 0.3.1 without local overrides.

Pushing a tag before committing the release files uses the previous package version and workflow. Rerunning an old tag checks out its old workflow and package source; it does not include subsequent fixes. Each later release needs a new package version and a matching new tag.
