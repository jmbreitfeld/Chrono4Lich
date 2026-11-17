# Security policy

Chrono handles GemStone IV account passwords (through Lich's saved logins), a short-lived
GitHub sign-in, and optionally a GitHub token and a cron-job.org key. Problems with how it
handles any of these are taken seriously.

## Reporting a problem

Please report security problems **privately**, not in a public issue:

- On GitHub: the repository's **Security** tab > **Report a vulnerability**.
- Or in game: send a message to Peggyanne asking for a private way to share the details.

Say what you found, how to reproduce it, and which version of Chrono (Settings > About) and
Lich you used. You'll get an answer within a week, and a fixed release as soon as one is ready.
Credit is given in the release notes unless you'd rather not be named.

## Supported versions

Only the newest release gets fixes. Chrono checks for updates when it opens.

## How releases are protected

- Releases are built by GitHub Actions from this repository (`.github/workflows/release.yml`),
  with every action pinned to a reviewed commit, and with build provenance recorded.
- The Windows installer is code-signed through SignPath (see README.md, "Code signing policy").
- `SHA256SUMS.txt` lists every file's checksum and is signed with Chrono's release key
  (`SHA256SUMS.txt.sig`). Chrono's built-in updater refuses any download whose checksum list
  isn't signed with that key, whose checksum doesn't match, or whose version isn't the one
  being installed.
- A published release's files are never replaced.
