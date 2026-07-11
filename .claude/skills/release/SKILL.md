---
name: release
description: Build, sign, notarize, and release a new version of Archibald. Runs the local release script, updates docs/appcast.xml with release notes, commits, pushes, and publishes the GitHub release.
---

# Release Skill

Full release pipeline for Archibald. Invoke with `/release` or `/release 0.2.0`.

## Steps

When this skill is invoked, execute the following steps in order:

### 1. Determine the release version

- If the user provided a version argument (e.g. `/release 0.2.0`), use that.
- Otherwise, read the current `MARKETING_VERSION` from `archibald/archibald.xcodeproj/project.pbxproj` and ask the user what version to release (suggest current version as default).

### 2. Pre-flight checks

Before running anything, verify:
- Working tree is clean (`git status --porcelain` shows nothing, or only expected changes). If dirty, ask the user whether to proceed.
- Required env vars are set: `APPLE_TEAM_ID`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`. These are stored in `.env` at the project root — source it before checking (`. .env`).
- Required tools are available: `xcodebuild`, `hdiutil`, `xcrun`, `gh`.

### 3. Run the release script

Run the release script, piping in the version to handle the interactive prompt:

```bash
echo "$VERSION" | scripts/release-local.sh
```

This script will:
- Bump the build number in project.pbxproj
- Archive and export the app
- Create and sign the DMG
- Notarize and staple (unless NOTARIZE=0)
- Generate a Sparkle signature
- Create a GitHub release (draft) and upload the DMG
- Update docs/appcast.xml with a placeholder release notes entry

**IMPORTANT**: This step is long-running (several minutes for build + notarization). Use a generous timeout (600000ms / 10 minutes). Run it in the foreground so you can monitor output.

If the script fails, show the error output and stop. Do NOT retry automatically.

### 4. Collect release notes

After the script succeeds, ask the user what changed in this version. Suggest looking at:
```bash
git log --oneline $(git describe --tags --abbrev=0 HEAD~1 2>/dev/null || echo HEAD~10)..HEAD
```

Use their response to write proper release notes.

### 5. Update docs/appcast.xml release notes

The script already inserted a new `<item>` entry in `docs/appcast.xml` with placeholder notes (`Update release notes here`). Edit the `<description>` block of the **first** (newest) `<item>` to contain the actual release notes the user provided, formatted as an HTML list inside the existing `<![CDATA[...]]>` block.

### 6. Commit and push

Stage and commit the changed files:
- `docs/appcast.xml`
- `archibald/archibald.xcodeproj/project.pbxproj`

Use commit message: `release vX.Y.Z`

Then push to origin:
```bash
git push origin main
```

Ask the user before pushing if the current branch is not `main`.

### 7. Publish the GitHub release

The script creates the release as a draft. After pushing the appcast, publish it:

```bash
gh release edit vX.Y.Z --repo jamesrisberg/archibald --draft=false
```

### 8. Summary

Print a summary:
- Version released
- GitHub release URL: `https://github.com/jamesrisberg/archibald/releases/tag/vX.Y.Z`
- Appcast URL: `https://jamesrisberg.github.io/archibald/appcast.xml`
- Remind: existing users will get the update automatically via Sparkle
