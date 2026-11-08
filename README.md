# Chrono (Chrono4Lich)

Log GemStone IV characters in and out through [Lich5](https://github.com/elanthia-online/lich-5), by hand or on a schedule, on Windows and Linux.

- **Characters:** tick as many characters as you like and log them in or out together.
- **Schedules:** log characters in and out at set times on chosen days, even with the Chrono window closed.
- **Logins:** add, update or remove Lich's saved logins without opening Lich. Supports every Lich frontend, plus Warlock.
- **Rewards (optional):** claim your monthly subscription SimuCoins, and optionally each character's daily login reward, every day. This can run on your PC or on your own GitHub account, so it works while your PC is off.

## Download

Get the latest version from the [Releases](../../releases/latest) page:

- **Windows:** `Chrono4Lich-setup-VERSION.exe`. Run it; no admin rights needed.
- **Linux:** `Chrono4Lich-linux.tar.gz`. Unpack it and run `./install.sh`.

You need Lich5 already installed and working, with its own Ruby. Full instructions are in [README.txt](README.txt), which is also included in every download.

## Privacy policy

Chrono runs on your computer and has no server of its own. It collects nothing, and it never sends information anywhere except as described below, each time because you asked it to:

- **Simutronics** (`eaccess.play.net`, `store.play.net`): your account name and password go here, encrypted, when you add a login, change a password, or claim rewards. This is the same login service Lich and the game use.
- **GitHub:** only if you choose "Claim on GitHub" on the Rewards tab. The logins for the accounts you pick are encrypted on your computer and stored as secrets in a **private** repository on **your own** GitHub account. Chrono never keeps your GitHub sign-in.

Passwords are never shown, logged, or written anywhere other than Lich's own saved-login file. Before changing that file, Chrono keeps a backup in `Lich5/data/chrono/backups`.

## Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

- The Windows installer is built from this repository's source by GitHub Actions ([release.yml](.github/workflows/release.yml)), then signed through SignPath. Every signing request is approved by hand.
- In Windows, the signature shows the signer as **SignPath Foundation**. To check it, right-click the installer, choose Properties, then Digital Signatures.
- The `.rb` files in the zip and Linux downloads are plain-text Ruby scripts and can't carry a signature. Each release lists SHA-256 checksums of its files in `SHA256SUMS.txt`.

**Team roles**

| Role | Member |
|---|---|
| Author, committer and reviewer | Peggyanne |
| Approver (approves each signing request) | Peggyanne |

Found a file signed this way that you don't trust, or a problem with this policy? Open an issue on this repository.

## Credits

- [Lich5](https://github.com/elanthia-online/lich-5) by Elanthia Online. Chrono drives Lich and uses its saved logins.
- [simu-rewards](https://github.com/elanthia-online/simu-rewards) by Ondreian. Chrono's reward claiming works the same way, and the GitHub option runs it.
- elogin.lic, which inspired the original version.

Chrono is a fan project and isn't affiliated with or endorsed by Simutronics. GemStone IV is a trademark of Simutronics Corp.

## License

[MIT](LICENSE). Copyright (c) 2026 Peggyanne.
