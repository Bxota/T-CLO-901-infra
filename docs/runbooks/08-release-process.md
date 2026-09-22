# Release process

## App releases

Work on \`dev\`, then merge a Conventional Commit pull request into protected \`main\`. A push to \`main\` runs \`release-candidate\`. It tests PHP and Helm, computes the next version, publishes an immutable multi-architecture image and OCI chart, then creates \`vX.Y.Z-rc.N\`. Stage follows the highest version matching \`>=1.0.0-0\`.

Run the \`promote\` workflow with an rc tag, or leave the input empty to select the highest rc. Promotion retags the tested image digest, packages the chart from the rc commit, and creates the stable \`vX.Y.Z\` tag and release. It never rebuilds the image.

## Platform releases

After reviewing platform changes, create an infra tag manually:

\`\`\`bash
git tag v1.3.0
git push origin v1.3.0
\`\`\`

The \`pin-release\` workflow commits the platform Application's \`targetRevision\` to that tag on \`main\`. Argo CD then reconciles the tag through the root app-of-apps.

## Rollback

For prod or stage, replace that child Application's chart range with an exact version such as \`1.0.0\` in a reviewed commit. Restore the range after a fixed release is available. For the platform, pin \`platform/apps/platform.yaml\` to an earlier infra tag.

## Troubleshooting

- No candidate: verify a stable tag and Conventional Commit history; \`no release\` is an intentional green no-op.
- Artifact already exists: versions are immutable; do not overwrite or delete the image/chart.
- Argo CD does not move: run \`argocd app get <app> --refresh\`, verify the GHCR chart is public, verify range syntax, and verify OCI support in the installed Argo CD.
- Stage admission rejection: check the namespace label, resource requests/limits, and \`ghcr.io/bxota/\` image prefix.
- Failed push after image publication: rerun the workflow; no git tag is created until the chart push succeeds.

## Defence sequence

Merge \`feat: break readiness probe\` and observe \`v1.1.0-rc.1\) in stage while old pods keep serving. Merge \`fix: restore readiness probe\`, promote \`v1.1.0-rc.2\), then verify prod and demonstrate rollback by pinning prod to \`1.0.0\`.

