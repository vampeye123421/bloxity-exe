# Client releases

The client repository is private. GitHub Actions builds a Windows export with its PCK embedded, wraps it in a one-file Inno Setup installer, replaces the installer in the private website repository's `public/client` folder, and updates `public/client/version.json`. Render then serves the installer publicly through the website without exposing either source repository.

## One-time setup

1. Add a fine-grained GitHub token as the `WEBSITE_REPO_TOKEN` Actions secret in this private repository. Grant it Contents read/write access to `vampeye123421/Bloxity`; the workflow uses it to replace the hosted installer and update the website manifest.
2. Push the client source and `.github/workflows/release-windows.yml` to this repository.
3. Push a version tag, for example `v1.0.4`. Wait for **Build and publish Windows client** to complete, then install the generated `BloxityClientSetup.exe` from the website's Download page once.

Existing installs cannot update themselves to the new updater: their old executable only knows how to download a separate PCK. They need this one-time installer update. The installer registers `bloxity://` and installs the embedded-PCK client.

## Later releases

After pushing client changes, publish by pushing the next semantic-version tag:

```powershell
git tag v1.0.5
git push origin v1.0.5
```

The workflow builds and publishes the installer, computes its SHA-256, updates the website manifest and installer file, and lets the website deployment publish the new version. Installed Windows clients check that manifest on launch, verify the installer checksum, update silently, and relaunch while preserving a pending `bloxity://` join link. It stops rather than trying to commit installers of 95 MiB or more because GitHub rejects single files at 100 MiB; that case needs dedicated object storage.

The matchmaking server does not need release-pipeline changes; installer metadata is served by the website. The client and server must still treat server-side authorization and gameplay validation as authoritative because a local client can be modified.
