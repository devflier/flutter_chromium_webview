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

## Prepared release

The next versions are interface **0.1.3** and webview **0.3.1**. Webview requires interface `^0.1.3` because it uses the named-profile API. Publish the interface first.

Local preparation checks: workflow YAML parses, both new tags pass the version guard, and the mismatched `v0.4.0` tag is rejected. Publication dry runs inspect both package archives; their only warnings are the uncommitted version/changelog files. The main package also reports the local dependency override, and both packages hint about skipped version numbers. These dry runs have not authenticated to pub.dev or published anything.

1. Commit and push the prepared package versions, changelogs, tag-check script and publishing workflow. Wait for validation to pass on that commit.
2. Create and push the interface tag on that validated commit:

   ```sh
   git tag platform_interface-v0.1.3
   git push origin platform_interface-v0.1.3
   ```

3. Confirm the interface publishing run succeeds and pub.dev lists 0.1.3.
4. Create and push the main package tag on the same validated commit:

   ```sh
   git tag v0.3.1
   git push origin v0.3.1
   ```

5. Confirm the main publishing run succeeds and pub.dev lists 0.3.1.

Push the individual tags rather than all local tags. Rerunning an old tag checks out its old workflow and package source; it does not include the new authentication fix. Each later release needs a new package version and a matching new tag.
