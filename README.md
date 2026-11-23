# Shelfmark for KOReader

Search a self-hosted Shelfmark server from KOReader, browse book details and available editions, and request downloads on the server. The plugin interface is currently in German.

## Features

- Search by **Allgemein** (general), **Autor** (author), or **Titel** (title).
- Choose an enabled and available metadata provider under **Such Bibliothek**. The initial selection uses Shelfmark's configured default provider.
- View covers, descriptions, authors, publication years, and library availability when supplied by Shelfmark.
- Select an edition and request its download on the Shelfmark server.
- Browse **Abgerufen** (requested books) with download status and an offline activity cache. A successful refresh replaces the saved list. Failed or incomplete refreshes preserve it.
- Reuse up to 64 recently viewed activity covers across restarts. Covers are cached as you browse.
- Open the title search in an OPDS Plus catalog using **Buch öffnen** (open book).

Book downloads run on Shelfmark. To obtain the resulting book on the reader, use an OPDS catalog or your server's configured delivery workflow. Calibre-Web or Calibre-Web Automated can provide the catalog when configured to import Shelfmark downloads.

## Compatibility

| Component | Supported or tested scope |
| --- | --- |
| KOReader | Tested using v2026.07.1 in a Linux simulator. Earlier versions have not been verified. |
| Devices | No device-specific native binaries. Physical Kindle, Kobo, PocketBook and Android testing remains open. |
| Shelfmark | Requires the metadata search, book details, release search, download queue and activity APIs listed below. A minimum Shelfmark release has not yet been established. |
| Authentication | Username/password session login through `/api/auth/login`, or a server allowing API access without login. Browser-based SSO is not implemented. Custom HTTP headers can be configured. |
| OPDS Plus | The catalog handoff was tested with v1.2.0 and an isolated OPDS catalog. Required for **Buch öffnen**. |
| Catalog | Must advertise an OPDS search endpoint. |

The smoke test uses stand-ins for KOReader and Shelfmark. The end-to-end Action runs the official KOReader v2026.07.1 Linux application, OPDS Plus v1.2.0 and a pinned Shelfmark v1.7.0 container. Real authentication, HTTP routes, widgets, queue processing and file output are exercised. Metadata and download-source adapters supply a generated test book. Physical-device testing against a personal Shelfmark installation remains open.

Shelfmark API endpoints used by the plugin are `/api/auth/login`, `/api/metadata/providers`, `/api/metadata/search`, `/api/metadata/book/<provider>/<id>`, `/api/releases`, `/api/releases/download`, `/api/activity/snapshot`, `/api/activity/history` and the fallback `/api/status`. Cover URLs come from the server response.

## Installation

1. Download `shelfmark.koplugin-v0.1.1.zip` from [Releases](https://github.com/SyntaxSorcerer7/shelfmark.koplugin/releases).
2. Extract it and copy the contained `shelfmark.koplugin` directory into your KOReader data directory's `plugins` folder.
3. Restart KOReader and enable Shelfmark in plugin management if necessary.
4. Open **Shelfmark** from the KOReader file browser menu.

For installation from source, copy this repository into `plugins/shelfmark.koplugin/`. The repository root contains `main.lua` and `_meta.lua` and can be used directly as the plugin directory.

## Setup and usage

Open the gear menu and set **Serveradresse** to your Shelfmark base URL, for example `https://shelfmark.example.org`. Enter **Benutzername** and **Passwort** when your server requires a username and password. Configure any additional access headers under **HTTP-Header**.

Shelfmark needs a configured metadata provider and a working download source. The plugin's **Such Bibliothek** selector fetches the current provider list and includes entries whose `enabled` and `available` flags are both true.

Tap the search bar, select the search type and optionally the search library, enter a query, then tap **Suchen**. Switching between search types retains your query and selected provider. Opening a new search dialog resets the type to general and the provider to the server default.

Select a result to see the book details and available editions. Selecting an edition opens a confirmation before requesting the download. Existing library items and collection matches are marked when Shelfmark provides that information.

The home screen shows the saved activity list immediately, then attempts a refresh. Active requests are refreshed about every 20 seconds after a successful server response. Use **Abgerufen aktualisieren** in the gear menu to refresh manually. Offline pages use saved cover files where available.

### OPDS Plus

Install and enable [OPDS Plus](https://github.com/greywolf1499/opds_plus.koplugin) and configure a catalog there. Choose it under **OPDS-Plus-Katalog auswählen**. If there is only one catalog, the plugin can select it automatically.

**Buch öffnen** on a completed request or an existing library item opens a title search in that catalog. Select the matching book in OPDS Plus to download it. OPDS Plus manages its own catalog credentials. Shelfmark completion can precede catalog import, so a book may appear later. Older activity items may contain filenames instead of clean titles.

## Stored data and security

The plugin writes these files under KOReader's `settings` directory.

| File or directory | Purpose |
| --- | --- |
| `shelfmark.lua` | Server address, username, password, custom headers and catalog preference |
| `shelfmark-activity-cache.lua` | Last complete activity list, scoped to the configured server and username |
| `shelfmark-cover-cache.lua` | Cover-cache index |
| `shelfmark-covers/` | Up to 64 recently used activity cover images |

Passwords, custom headers and cached reading activity are stored unencrypted. Session cookies remain in memory and are cleared when Shelfmark closes, when it hands off to OPDS Plus, or when access settings change. Use access credentials appropriate for the device and protect backups of its settings.

HTTP sends credentials and activity in clear text. HTTPS protection also depends on the KOReader build and its networking libraries. This plugin does not add certificate verification to KOReader's HTTP transport. Redirects are not followed, so configure the final server address.

To clear the offline activity and cover caches, close KOReader and delete the three cache paths listed above. Preserve `shelfmark.lua` to retain your setup.

## Known limitations

- Requests run synchronously. The interface can pause while a server request is in progress.
- Metadata-provider field support depends on the server and provider.
- The activity list reflects Shelfmark activity, rather than a complete catalog inventory.
- Library flags depend on Shelfmark's library-check configuration and response data.
- Temporary detail cover files can remain after a crash or forced shutdown.
- A server or account change replaces the activity-cache scope on the next successful refresh. This cache stores one account's latest list at a time.

## Development and tests

Run the smoke test from the repository root with LuaJIT.

```sh
luajit tests/smoke.lua
```

The test uses synthetic credentials, responses and temporary files. It requires a Unix-like environment with `mkdir` and `rmdir`. It checks search parameters, session renewal, activity restoration and refresh failures, the 64-cover limit, OPDS handoff and lifecycle cleanup.

### End to end checks

The **End-to-end tests** Action runs on branch pushes and pull requests and can also be started manually from GitHub Actions. Release publication depends on its successful completion.

The Action starts a pinned Shelfmark container and launches the real KOReader Linux application under Xvfb. `tests/e2e.lua` drives real dialog and menu callbacks through a late user patch. It checks author search, active-provider filtering, authenticated search results, book details, edition confirmation, completed server-side EPUB output, cached activity and covers, and the OPDS Plus search handoff. It then stops Shelfmark and starts a fresh KOReader process with the same isolated settings to verify offline restoration and preservation after a failed refresh.

Logs, screenshots and pass markers are uploaded as the `e2e-results` artifact for seven days, including on failures. Each KOReader scenario has a two-minute timeout and the job has a fifteen-minute limit. No personal account or external book source is required.

`tests/e2e_server.py` replaces external metadata and download-source adapters with deterministic fixtures. Shelfmark's routes, authentication, registry checks, queue and post-processing remain active. The fixture creates its own synthetic credentials, EPUB and database under `/tmp/shelfmark-e2e-auth` inside the disposable container. The pinned dependencies are declared in `.github/workflows/e2e.yml`.

Build the installable archive with Python 3.

```sh
python3 tools/package.py
```

The archive is written to `dist/` and contains the runtime files, README and license. Tests and development tooling remain in the source repository.

Report issues with KOReader, Shelfmark and OPDS Plus versions, device model, reproduction steps and relevant logs. Remove passwords, cookies, personal URLs and custom access headers before sharing logs.

## Publishing a release

Pushes and pull requests run the smoke tests and build and check the installable archive. Pushing a tag beginning with `v` also runs the release workflow. Publication starts only after the smoke and end-to-end checks pass and the tag exactly matches the version in `_meta.lua`.

To publish a new version, update `_meta.lua`, commit and push that change, then tag the commit and push the tag. For example, with `version = "0.2.0"` committed on `main`, run the following commands.

```sh
git tag v0.2.0
git push origin v0.2.0
```

The workflow creates a GitHub Release with generated notes and attaches the installable ZIP. Versions with a suffix such as `0.2.0-rc.1` produce prereleases. Retrying a run replaces the ZIP on an existing release while preserving its notes. The workflow uses GitHub's built-in token with release-write permission confined to the publishing job.

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE). This is an independently maintained community plugin.
