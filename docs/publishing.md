# Publishing to pub.dev

## Release 0.5.3 procedure — 2026-10-14

The public main package is currently 0.5.2. Prepare 0.5.3 with matching pubspec,
changelog, README and examples. Publish platform interface 0.1.6 before the main package, which requires
`^0.1.6`. The published 0.1.5 interface lacks APIs present in the local override.
Preserve every old tag.

1. Use clean main source, excluding local profiling fixtures and native experiments.
2. Run formatting, analyzers, unit/example tests and publication dry runs with
   the declared SDK constraints satisfied. Do not lower constraints to bypass
   an older local SDK. CI pins Flutter 3.47.4 and Dart 3.13.3.
3. Run the unified workflow manually on the candidate to include macOS. Ordinary
   branch/main pushes skip macOS. Preserve all failed stages and artifacts.
4. Review [release readiness](release-readiness.md), including the unresolved
   historical memory acceptance and blocked physical 8 GB verification. A short
   CI pass does not erase those verdicts. Record any owner-approved release
   exception explicitly; do not describe it as memory acceptance.
The owner approved stable 0.5.3 with these documented memory limitations on
2026-10-14; see release readiness. This does not waive configured CI failures.

5. Commit and push the approved candidate, verify `v0.5.3` matches pubspec using
   `GITHUB_REF_NAME=v0.5.3 bash scripts/check_release_tag.sh packages/flutter_chromium_webview v`,
   first create/push the new `platform_interface-v0.1.6` tag on the approved
   source and confirm its publishing workflow and public version endpoint.
   Then create/push only the new `v0.5.3` tag. Tag pushes start automated publication after
   quality, Linux, Windows, Android and macOS validation jobs all succeed.
The main publishing job removes the repository-only dependency override and
   reruns dependency resolution, analysis, tests and dry-run validation against
   the actual published interface before uploading. The archive excludes both
   main/example override files; the example's ordinary pubspec keeps its parent
   package path without referencing an unavailable sibling repository.

6. Inspect the publishing job and confirm the public version endpoint for 0.5.3.
   A pushed tag or successful dry run alone is not proof of publication.

## Automated publishing account setup

Configure each package's Admin → Automated publishing settings for repository
`devflier/flutter_chromium_webview`: main tag pattern `v{{version}}`, interface
pattern `platform_interface-v{{version}}`. If pub.dev requires an environment,
the workflow must declare the same environment. Public package metadata cannot
verify these private settings. GitHub OIDC authentication is supplied by
`dart-lang/setup-dart`; no credentials belong in release files.

See [Dart automated publishing documentation](https://dart.dev/tools/pub/automated-publishing).
Never retag a historical release to fix source/version mismatches; use a new
version and tag. Publication changes the public package and must retain the
exact validated source and documented limitations.
