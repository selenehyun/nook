# Homebrew tap setup

Nook ships a Homebrew **cask** through a custom tap so people can install it with:

```sh
brew install --cask selenehyun/tap/nook
```

The release workflow (`.github/workflows/release.yml`) generates the cask
(`Casks/nook.rb`) on every published release — filling in the version and the
DMG's SHA-256 — and pushes it to the tap repository. This is a **one-time
setup**; after it's in place, releases keep the cask up to date automatically.

## One-time setup

1. **Create the tap repository.** A Homebrew tap must be a repo named
   `homebrew-<tap>`. Create a public repo **`selenehyun/homebrew-tap`** (empty is
   fine — the workflow creates `Casks/nook.rb`). Users reference it as
   `selenehyun/tap`.

2. **Add a write deploy key to the tap.** A deploy key is scoped to the single
   repo, so it's cleaner than an account-wide token. Generate a keypair:

   ```sh
   ssh-keygen -t ed25519 -f homebrew-tap-deploy -N "" -C "nook-cask-publish"
   ```

   Then in **`selenehyun/homebrew-tap`** → Settings → Deploy keys → **Add deploy
   key**: paste the contents of `homebrew-tap-deploy.pub` and **check "Allow
   write access"**.

3. **Add the private key as a secret on this repo.** In `selenehyun/nook` →
   Settings → Secrets and variables → Actions → **New repository secret**:
   - Name: `HOMEBREW_TAP_DEPLOY_KEY`
   - Value: the full contents of `homebrew-tap-deploy` (the **private** key,
     including the `-----BEGIN/END OPENSSH PRIVATE KEY-----` lines)

   Delete the local key files afterward. Without this secret the cask-publish
   step logs a message and skips, so releases still succeed.

   (A fine-grained PAT with Contents: write would also work, but then the
   workflow would need to clone over HTTPS instead of SSH.)

4. **Cut a release** (push a `vX.Y.Z` tag). The workflow publishes the DMG, then
   writes `Casks/nook.rb` into the tap and pushes it.

## Notes

- **Not notarized.** The build is ad-hoc signed, so a cask-installed copy is
  still quarantined by default. The cask's `caveats` explain the right-click /
  `xattr` unlock, and `HOMEBREW_CASK_OPTS="--no-quarantine" brew install …`
  skips it. Notarizing (an Apple Developer
  account) would remove that friction and is the prerequisite for submitting to
  the official `homebrew/cask` tap.
- **Updates.** The cask sets `auto_updates true` because the app updates itself
  via Sparkle; `brew upgrade` still re-installs the latest cask version.
- **Uninstall.** `brew uninstall --cask nook`; `brew uninstall --zap --cask nook`
  also removes preferences/caches. Zap never touches your chosen sync folder —
  that's your data.
