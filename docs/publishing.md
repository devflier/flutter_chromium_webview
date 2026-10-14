# Release preparation and publishing

## Approval boundary

No package publication, merge or tag action is authorized by the CI-redesign
request. The earlier stable-release decision does not authorize these actions
under the new instruction. PR #6 contains preparation only. Existing tags stay
unchanged. In particular, the unpublished `platform_interface-v0.1.6` tag points
to the old workflow at f202e72; rerunning it will still use that old dependency
graph. Before release, the owner must approve either retargeting that
**unpublished** tag to reviewed source, or a new version/tag. Do not move it as
an automatic CI fix.

## Relevant release gates

- Interface: `interface_checks` analyzes/tests exported API and method-channel
  contracts, validates/builds the in-memory example and dry-runs publication.
  `quality` compiles/analyzes/tests the plugin consumer against the local
  candidate interface. Both must pass; no native/live/soak dependency exists.
- Plugin: quality and Linux/Windows/Android native jobs, deterministic macOS
  core, local decoded-media RSS/ownership acceptance, and actual published
  dependency readiness must pass. Failed or missing jobs cannot publish.
- `macos_youtube_live` is explicitly invoked through the workflow input. It
  remains independently reported and nonzero on FAIL/BLOCKED. External
  challenges cannot certify success or block unrelated interface publication.
- Historical strict RSS failures remain failed. A new local-media profile pass
  is a different workload, not a replacement YouTube or long-term acceptance
  result. Any unresolved memory release decision must be reviewed explicitly.

## Prepared release sequence (execute only after approval)

1. Review PR #6 and complete relevant readiness checks; authorize a specific
   source commit and interface tag/version strategy. Because GitHub/OIDC
   publication runs on tags, an approved interface tag must precede the actual
   upload. The current old tag cannot inherit the new workflow.
2. Publish interface 0.1.6 through its independently gated tag workflow. Confirm
   its public version endpoint and archive/source checksum.
3. Validate plugin 0.5.3 without local development overrides:

   ```sh
   bash scripts/verify_public_dependencies.sh
   # Or invoke workflow_dispatch with public_dependencies=true.
   ```

   This requires hosted interface0.1.6, runs package and example analysis/tests,
   dry-runs packaging and restores development overrides afterward. If the
   version is not yet published, readiness is BLOCKED; never silently use a path.
4. Complete deterministic native and memory gates. Inspect explicit live-service
   results independently and document product risks. Merge only reviewed and
   explicitly approved changes. Verify the resulting tree matches validation.
5. With explicit plugin-release approval, create/push the new plugin tag; the
   tag workflow reruns required checks before uploading. Do not describe a
   successful tag push as successful publication.

Example commands for the approved source (not executed during preparation):

```sh
GITHUB_REF_NAME=platform_interface-v0.1.6 bash scripts/check_release_tag.sh packages/flutter_chromium_webview_platform_interface platform_interface-v
# Only after the owner resolves/approves the already-existing unpublished tag:
# git tag platform_interface-v0.1.6 APPROVED_COMMIT
# git push origin refs/tags/platform_interface-v0.1.6
curl --fail https://pub.dev/api/packages/flutter_chromium_webview_platform_interface/versions/0.1.6
bash scripts/verify_public_dependencies.sh
GITHUB_REF_NAME=v0.5.3 bash scripts/check_release_tag.sh packages/flutter_chromium_webview v
# git tag v0.5.3 APPROVED_MERGED_COMMIT
# git push origin refs/tags/v0.5.3
curl --fail https://pub.dev/api/packages/flutter_chromium_webview/versions/0.5.3
```

The dedicated readiness job performs main/example analysis and tests once.
The upload job resolves the same hosted dependency again in its fresh checkout,
checks its origin/version and repeats only final archive validation before
uploading. Native suites are not duplicated inside publishing jobs.

## Account configuration

GitHub OIDC via dart-lang/setup-dart requires the correct repository and tag
pattern in each package's pub.dev Admin → Automated publishing settings:
`v{{version}}` for plugin, `platform_interface-v{{version}}` for interface.
Private account settings cannot be inferred from public metadata. If an
approval environment is configured, the workflow must match it. No credentials
belong in source. Do not bypass account protection or package integrity.
