# Releasing Pawxy with Sparkle

Pawxy publishes ad-hoc signed builds through GitHub Releases. Sparkle verifies every update with a separate EdDSA key, so the update channel remains authenticated even without a paid Apple Developer ID certificate.

## One-time setup

1. Create the GitHub repository and add it as this checkout's `origin`.

   ```sh
   git remote add origin git@github.com:YOUR_ACCOUNT/Pawxy.git
   git push -u origin main
   ```

2. Locate Sparkle's key tool after opening or building the project in Xcode.

   ```sh
   find "$HOME/Library/Developer/Xcode/DerivedData" \
     -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys' \
     -type f -print -quit
   ```

3. Export the existing Pawxy private key from the login Keychain into a temporary file. Do not commit or share this file.

   ```sh
   /path/from/the/previous/command/generate_keys \
     --account com.dreamcorp.Pawxy \
     -x /tmp/PawxySparklePrivateKey
   ```

4. Add it to the GitHub repository as an Actions secret, then move the temporary file to the Bin.

   ```sh
   gh secret set SPARKLE_PRIVATE_KEY < /tmp/PawxySparklePrivateKey
   ```

Keep an encrypted backup of this private key. Losing it prevents installed copies of Pawxy from trusting future updates. The public key is already embedded in the Xcode project and is safe to commit.

## Publish a release

Use an annotated semantic-version tag after preparing the version and build
number in the project.

```sh
git tag -a v1.0.0 -m "chore(release): prepare v1.0.0"
git push origin v1.0.0
```

The `Release Pawxy` GitHub Action then:

1. builds an ad-hoc signed Release app;
2. injects the current GitHub repository into `SUFeedURL`;
3. generates categorized release notes from every commit since the previous tag;
4. excludes the mechanical `chore(release): prepare` commit from those notes;
5. creates a ZIP preserving macOS metadata;
6. embeds the same release notes in the Sparkle appcast;
7. signs the update with Sparkle EdDSA;
8. publishes the notes, ZIP, `appcast.xml`, and SHA-256 checksum to GitHub Releases.

You can preview the generated notes before tagging:

```sh
Scripts/generate-release-notes.sh v1.0.0 /tmp/Pawxy-release-notes.md
cat /tmp/Pawxy-release-notes.md
```

Do not manually replace a ZIP after publishing it. Create a new version and tag so that the Sparkle signature, version metadata, and archive always agree.
