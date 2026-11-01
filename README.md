# Github Manager

Github Manager by Namgyal is a native macOS SwiftUI app for syncing selected
files between a local folder and GitHub. Connect your GitHub account with
OAuth Device Flow, choose a repository, and upload or download files without
leaving the app.

## Features

- Browse a local folder and select multiple files to upload. Hidden files,
  symbolic links, package descendants, and `.git` contents are skipped.
- Browse and search repositories available to the authorized GitHub account,
  including private repositories the account can access.
- Upload selected files to the repository's default branch with a commit
  message. Files are limited to 100 MB each.
- Download the selected repository's default branch into the chosen local
  folder. Existing files at matching paths are replaced.
- Create repositories, private by default, or choose public visibility.
  Repositories created by the app are initialized with a README.
- Change the selected repository between private and public after reviewing
  an explicit confirmation. Making a repository public exposes its contents
  and commit history to everyone; making it private cannot recall existing
  clones, forks, or copies.
- Browse repository branches and select multiple files to delete. The app
  presents a separate confirmation showing the repository, branch, count, and
  exact paths before sending any deletion request. Each file deletion creates
  its own commit; if some deletions fail, the app reports the partial result.
- View upload, download, repository creation, and deletion progress and
  errors in the activity log. The log retains the latest 200 entries.
- Use a native macOS window with a live translucent, blurred backdrop.

Uploads to an already-empty repository bootstrap the branch using the first
selected file. If additional files were selected, they are committed in a
following commit. Repositories created in the app are initialized so the
normal upload path can be used.

## Requirements

- macOS 14 or later
- The full Xcode app and its Swift toolchain
- Xcode's license and Apple SDK terms reviewed and accepted

The standalone Command Line Tools alone may not include the SwiftUI macro
plug-ins needed to build this app. The app has been built with Xcode 27.2 and
Swift 6.4.2.

If more than one Apple developer directory is installed, select the full Xcode
installation before building:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

Review and accept the Xcode license interactively before using the toolchain:

```sh
sudo xcodebuild -license
```

## Build and run

Clone this repository and enter its folder:

```sh
git clone https://github.com/namgyalls/github-manager.git
cd github-manager
```

Build and sign Github Manager:

```sh
chmod +x build-github-folder-sync.command
./build-github-folder-sync.command
```

The build script compiles `GitHubFolderSyncApp.swift`, copies
`GitHubFolderSyncInfo.plist`, signs the app locally, and verifies the bundle.
By default, the result is:

```text
GITHUB_SYNC_BUILD/Github Manager.app
```

Open it from the repository directory:

```sh
open "GITHUB_SYNC_BUILD/Github Manager.app"
```

To build in a different location, set `OUTPUT_DIR`:

```sh
OUTPUT_DIR="$HOME/Applications/GithubManagerBuild" ./build-github-folder-sync.command
```

The script refuses to overwrite an app bundle already present at its output
path. Choose a new output directory if that happens. The app is ad-hoc signed,
not notarized; macOS may display a security warning when you first open a
locally built copy.

## Standalone app bundle

The build produces a self-contained `Github Manager.app`: its compiled
executable, `Info.plist`, icon, and code signature are inside the bundle. The
app does not load source files, images, configuration files, or other
resources from the repository or build directory at runtime.

The app links against Apple system frameworks (`AppKit`, `SwiftUI`, and
`Security`) and the Swift runtime provided by macOS. Those platform components
are supplied by the operating system and should not be copied into the app
bundle. The standalone app still requires a compatible Mac (macOS 14 or later);
the source checkout and Xcode are not needed to launch an already-built app.
Ad-hoc signing is for local use and does not provide notarized distribution.

The original Github Manager folder-and-branch icon is sourced from
`Resources/GithubManagerIcon.png`, provided as a high-resolution editable PNG,
and bundled as `Contents/Resources/GithubManager.icns`.

## Connect a GitHub account

Github Manager uses GitHub's OAuth **Device Flow**. You must register an
OAuth App and enter its public Client ID in Github Manager. The app does not
use Google sign-in and does not need an OAuth client secret.

### 1. Register an OAuth App

1. Sign in to GitHub with the account that will own the OAuth App.
2. Open **Settings** from your profile menu.
3. In the settings sidebar, choose **Developer settings**.
4. Choose **OAuth Apps**, then select **New OAuth App** (or **Register a new
   application** if this is your first OAuth App).
5. Give the app a name, such as `Github Manager`. Use only public information
   in the app's registration details.
6. For **Homepage URL**, use a public page describing the app. For this
   repository, you can use
   `https://github.com/namgyalls/github-manager`.
7. For **Authorization callback URL**, enter a valid HTTPS URL, such as the
   same public repository URL. GitHub requires a value in the OAuth App
   registration form, but Github Manager uses Device Flow: it does not
   redirect to or use this callback URL.
8. Enable **Device Flow**. This setting is required for Github Manager to
   request a device code.
9. **Disable “Expire user access tokens” for this OAuth App.** The app stores
   and uses the access token but does not currently implement refresh-token
   renewal. GitHub enables token expiration by default for new OAuth Apps;
   leaving it enabled can cause authorization to stop working when the token
   expires.
10. Select **Register application**.

GitHub's official guides:

- [Create an OAuth App](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app)
- [Authorize OAuth Apps and use Device Flow](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow)
- [OAuth App scopes](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)

### 2. Copy the Client ID

On the newly registered OAuth App's settings page, copy its **Client ID**.
This is a public identifier, not a password. Do not copy or enter a Client
Secret; Github Manager does not use one.

### 3. Authorize from Github Manager

1. Launch **Github Manager** and choose **Connect account**.
2. Paste the OAuth App's Client ID into **OAuth App Client ID**, then choose
   **Authorize with GitHub**.
3. Github Manager requests the device authorization from GitHub and opens
   GitHub's verification page. If it does not open automatically, use the
   verification URL shown by the app.
4. Enter the one-time user code displayed in the app and approve access for
   the GitHub account you want to connect.
5. Keep Github Manager open while it waits for authorization. When complete,
   the app verifies the account and loads its repositories.

The app requests the OAuth scopes `read:user` and `repo`. `read:user` is used
to identify the connected account. GitHub's `repo` scope grants broad
read/write access to public and private repositories that the authorizing
account can access; GitHub also documents that this scope can cover other
repository-related capabilities. Review the authorization screen and only
authorize an OAuth App you trust.

The Client ID is saved in the app's preferences so it is available the next
time you connect. The returned access token is stored in the macOS Keychain
with device-only accessibility. The app sends it to GitHub over HTTPS for
repository listing and the actions you initiate. It is not embedded in this
repository or app source.

To sign out, choose **Sign out** in the GitHub panel. This removes the access
token saved by this app version from Keychain and clears the connected account
and repository selection. It keeps the public OAuth Client ID so you can
authorize again without re-entering it. Sign out is local; it does not revoke
the OAuth App's authorization in GitHub account settings.

The Keychain service name is tied to this app's current bundle identity. When
upgrading from older builds named Folder -> GitHub or Github Folder Sync, their
Keychain entry may be owned by the earlier app identity and cannot safely be
deleted by this version. This version does not read or alter that legacy entry.
To invalidate an authorization saved by an older build, open GitHub **Settings
> Applications > Authorized OAuth Apps**, select the Github Manager OAuth App,
and choose **Revoke**. Then connect again in the current app; its token is
stored in the current app's Keychain service. Revoking on GitHub invalidates
the old authorization even if an inaccessible legacy Keychain record remains.

## Use Github Manager

1. **Choose a local folder** with **Browse…**. The app lists regular files
   under that folder and skips hidden files and `.git` contents.
2. **Choose a repository** from the GitHub panel. Use search or refresh as
   needed. Upload and download use that repository's default branch.
3. **Upload files:** select files in the Local Folder panel, enter a commit
   message, and choose **Upload to GitHub**. A normal upload creates one
   commit. On a previously empty repository, the first selected file creates
   the initial branch commit; additional selected files are committed next.
4. **Download files:** choose a local destination folder and select
   **Download repository**. Files from the default branch are written into
   that folder; files already present at matching paths are replaced.
5. **Create a repository:** choose **Create repository**, provide a name and
   optional description, then choose private or public visibility. The form
   defaults to private and clearly identifies public repositories. Creating a
   repository is a GitHub account action.
6. **Change visibility:** the GitHub panel shows whether the selected
   repository is private or public. Choose **Make public…** or **Make
   private…**, then review the confirmation naming the repository and
   explaining who can see it and what cannot be recalled. Confirm only if the
   visibility change is intended. The app updates the selected repository's
   displayed visibility from GitHub's response and records the result in the
   Activity Log.
7. **Delete repository files:** choose **Delete files…**, select the branch
   and files, then choose **Review deletion…**. Check the listed repository,
   branch, count, and exact paths. Deletion occurs only after you choose the
   final **Delete N file(s)** confirmation button. GitHub creates one commit
   per deleted file. Changes made to a file after the list was loaded can
   cause that file's deletion to fail; the app reports stale-file and partial
   failures and refreshes the list.
8. **Monitor activity:** the Activity Log records operation progress,
   completion, and errors. It keeps the latest 200 entries.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| Device authorization cannot start | Confirm that you copied the Client ID from the right OAuth App and enabled **Device Flow** in that app's settings. |
| Authorization fails or times out | Enter the current one-time code at GitHub's verification URL before it expires. Restart authorization to request a new code. |
| GitHub rejects the token | Connect again and approve the requested access. If the OAuth App's access was revoked in GitHub settings, authorize it again. |
| No repositories appear | Confirm the connected GitHub account, then refresh. The account must have access to the repository; organization policies may also restrict OAuth Apps. |
| Repository action returns 403 or 404 | Check that the account has the required access and that the selected repository and branch still exist. Organization approval may be required. |
| Visibility change is rejected | The account needs permission to administer repository settings. For organization-owned repositories, an organization owner or repository admin may need to allow the change or grant sufficient access. |
| Empty-repository upload fails | The app handles empty repositories through an initial Contents API commit. Check the Activity Log for the specific GitHub error and confirm write permission. |
| File upload is rejected for size | GitHub Manager limits each uploaded or downloaded file to 100 MB. |
| Build says the Xcode license is not accepted | Open Terminal, run `sudo xcodebuild -license`, review the license and Apple SDK terms, and accept them only if you agree. |
| Build cannot find SwiftUI macro plug-ins | Install the full Xcode app, select it as the active developer directory if needed, and accept its license. The standalone Command Line Tools may be insufficient. |
| macOS warns about opening the app | Local builds are ad-hoc signed and not notarized. Build the app yourself from this source and follow macOS's normal security guidance. |

## Privacy and security

- Never share your one-time device code, OAuth access token, or Keychain
  contents. Do not paste credentials into issues or commit them to source
  control.
- The OAuth Client ID is public and is saved in local app preferences; it is
  not a client secret.
- The token is stored in the macOS Keychain. Revoke the OAuth App's access in
  GitHub account settings if you no longer want it authorized. In-app
  **Sign out** removes this version's saved token locally but does not revoke
  GitHub authorization. Older builds may have a separate Keychain entry
  owned by their previous app identity; revoke that authorization in GitHub
  **Settings > Applications > Authorized OAuth Apps**.
- `repo` is a broad OAuth scope that provides read/write repository access
  within the permissions of the authorizing account. Only connect an account
  whose access you intend to use with this app.
- Uploads, downloads, repository creation, visibility changes, and deletion
  communicate with GitHub when you explicitly start those actions. Public
  visibility changes and deletion require a separate confirmation in the app.
- Downloaded files are written into the chosen local folder and can replace
  files at matching paths. Review your destination folder before downloading.
- Activity log entries may contain repository names, file paths, commit
  identifiers, and error text. The log is local to the app session and is
  bounded to 200 recent entries.

## Repository contents

- `GitHubFolderSyncApp.swift` — Github Manager's SwiftUI interface, GitHub
  Device Flow, Keychain access, and repository operations.
- `GitHubFolderSyncInfo.plist` — macOS app bundle metadata.
- `Resources/GithubManagerIcon.png` — original high-resolution icon artwork.
- `Resources/GithubManager.icns` — macOS app icon copied into the app bundle.
- `build-github-folder-sync.command` — build, sign, and verify Github Manager.
No sample invoices, receipts, or user files are required to build Github
Manager. This repository does not include an open-source license; add one
before redistributing the code.
