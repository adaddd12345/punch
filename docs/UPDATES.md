# Shipping a beta: the update pipeline

No Apple Developer account is used. Builds are ad-hoc signed, and updates go out through **Sparkle 2** with an **EdDSA-signed** feed hosted on GitHub Releases. Everything is automated by `.github/workflows/build.yml`.

## How to ship
1. Commit and push to `claude/macos-audio-routing-research-xpbcuk`. That's it.
2. CI (`build` workflow, run number **N**) then does the following:
   - Linux: core tests plus ASan/UBSan.
   - macOS 26 runner (Xcode 26.6 pinned, macOS 26 SDK; deployment target 14.4):
     1. Run the core tests.
     2. Run `mac/scripts/bundle.sh "0.1.0-beta.N" N`. It builds a universal `The Bass Shaker.app`, ad-hoc signs it and zips it to `build/BassShake-0.1.0-beta.N.zip`.
     3. Publish the GitHub prerelease **`v0.1.0-beta.N`** with that zip.
     4. Sign the zip with `SPARKLE_ED_PRIVATE_KEY` using `mac/scripts/sparkle_appcast.py`. The release notes are the first line of the commit message. The script checks the signature against `SUPublicEDKey` in `Info.plist`.
     5. Overwrite `appcast.xml` on the fixed release tag **`updates`**.
3. The installed app reads `SUFeedURL` = `https://github.com/adaddd12345/punch/releases/download/updates/appcast.xml`:
   - It checks hourly, without stealing focus.
   - It also checks quietly when the popover opens, at most every 10 minutes.
   - The user can check now with ⋯ → Check for Updates….

## Rules
- **The workflow runs on every branch (`branches: ["**"]`), and they all share the one `updates` feed.** Pushing *any* branch ships to the user. To experiment without shipping, use a PR or a draft branch and change the trigger, or don't push.
- **Only push code that compiles.** There's no local Swift check without Xcode; CI is the compiler. Before telling the user a build is live, check the run succeeded (GitHub MCP `actions_list` / `get_job_logs`, or the Actions tab).
- **Commit messages:** write the first line as release notes, because users see it in Sparkle.
- **Version numbers:** `CFBundleVersion` = run number, which only increases. Never hand-edit versions; `bundle.sh` stamps `__VERSION__` / `__BUILD__` into `Info.plist`.
- **Signing key:**
  - Never print or commit the private key. It exists only as the repo secret `SPARKLE_ED_PRIVATE_KEY`.
  - If that secret is missing, CI still builds but skips the feed, with a warning.
  - Rotating the key means changing `SUPublicEDKey` too, and installed copies will then reject updates until they're reinstalled manually.
- **Parallel builds:** runs on the same ref publish one at a time (`concurrency: publish-<ref>`, no cancelling), so the feed always ends on the newest push.
- **Updates from the app** keep the existing install path (the old "Bass Shake.app" name survives a Sparkle update) and aren't quarantined.

## When an update won't arrive
- **Check what the feed says:** `curl -sL https://github.com/adaddd12345/punch/releases/download/updates/appcast.xml | grep -E 'shortVersionString|sparkle:version'`
- **Check what's installed:** `defaults read "/Applications/The Bass Shaker.app/Contents/Info.plist" CFBundleShortVersionString`
- **Manual install fallback.** This gets the newest beta, quits the app, swaps the copy in /Applications and relaunches:
  ```bash
  cd /tmp && URL=$(curl -s "https://api.github.com/repos/adaddd12345/punch/releases?per_page=5" | grep -o 'https://[^"]*BassShake-[^"]*\.zip' | head -1) && echo "$URL" && curl -L -o bs.zip "$URL" && rm -rf bsx && ditto -x -k bs.zip bsx && osascript -e 'quit app id "app.bassshake.BassShake"'; sleep 2; rm -rf "/Applications/Bass Shake.app" "/Applications/The Bass Shaker.app" && cp -R bsx/*.app /Applications/ && xattr -dr com.apple.quarantine "/Applications/The Bass Shaker.app" && open "/Applications/The Bass Shaker.app"
  ```
  After a manual install, macOS may ask again for the System Audio Recording permission.
- **Updater code lives in** `mac/Sources/BassShake/Updates.swift`:
  - It starts 2 s after launch and never shows a blocking alert; start errors appear in the ⋯ menu.
  - There are auto-check and auto-install toggles in ⋯ → Update Options.
  - The "What's New" banner appears after the version changes.
