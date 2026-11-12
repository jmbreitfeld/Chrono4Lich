Chrono (Chrono4Lich) - log GemStone IV characters in and out through Lich5, by hand or on a schedule
=====================================================================================================

Chrono used to be called lichsched. Installing Chrono replaces lichsched and keeps your
schedules and saved Lich folder.

WHAT YOU NEED
  - Windows 10 or 11, or desktop Linux with systemd (see LINUX below)
  - Lich5 installed with its own Ruby (on Windows, the Ruby4Lich5 installer; includes GTK)
  - Your Simutronics account(s). Saved logins can be added on Chrono's Logins tab, or in
    Lich's login window as before; both use the same saved logins.

INSTALL ON WINDOWS
  Easiest: run Chrono4Lich-setup.exe. It finds the Ruby that runs Lich (or lets
  you pick it), installs Chrono for your Windows user only (no admin needed), and
  adds desktop and Start menu shortcuts. Windows may warn about an unrecognized
  app the first time; click "More info", then "Run anyway".

  From the zip instead:
  1. Unzip the "Chrono4Lich" folder somewhere it can stay, for example your
     Documents folder. Don't put it inside Lich's "scripts" folder.
  2. Double-click install.bat. It finds the Ruby that runs Lich, checks it,
     and puts a "Chrono" shortcut on your desktop.

  Then open Chrono from the shortcut. The first time, it finds your Lich folder
  by itself, or asks you to pick it (the folder with lich.rbw in it). No saved logins
  yet? Add them on the Logins tab.

INSTALL ON LINUX (tested target: Pop!_OS with COSMIC; other systemd desktops should work)
  1. Unpack Chrono4Lich-linux.tar.gz, open a terminal in the Chrono4Lich folder, run:
       ./install.sh
     It finds the Ruby you run Lich with (rbenv and asdf too), checks that it has
     GTK, installs for your user only (no sudo) into ~/.local/share/Chrono4Lich,
     and adds Chrono to your applications menu plus a "chrono" command.
  2. Open Chrono from the menu. It finds your Lich folder (~/lich5 and other
     usual places) or asks you for it.
  Schedules use systemd user timers (~/.config/systemd/user/chrono-*). The
  computer must be on and awake at the scheduled time; unlike Windows, a sleeping
  computer isn't woken up. Failures show a desktop notification (notify-send;
  install with: sudo apt install libnotify-bin).

  Chrono copies its small in-game helper (chrono_helper.lic) into Lich's scripts
  folder by itself. You never need to run it by hand.

USING IT
  Characters tab: tick characters, then Log in selected / Log out selected /
    Log out all. Ticked characters log in at the same time (each one starts two
    seconds after the last, so they don't all hit the login server at once). "Force close" is only for when a normal logout fails; the
    character may stay linkdead in the game for a while.
  Schedules tab: New... makes a schedule (characters, days, login time, optional
    logout time, optional start scripts). Use "Test login now" to try one out.
  Rewards tab: claim your monthly subscription SimuCoins (and, if you want, each
    Prime character's daily login reward) every day at a time you pick. See REWARDS.
  Logins tab: laid out like Lich's account manager. Click an account to open its list of
    characters. On a character, click its Frontend to pick another from a dropdown
    (Warlock included). "Add account..." adds an account (type the account and password,
    click "Look up characters", tick the ones to save); "Add characters..." adds more
    characters to the selected account; "Change password..." after changing it on
    play.net; "Remove..." removes the selected character, or the whole account if an
    account is selected. Close Lich's login window first, or saving something there may
    undo the change.
    Warlock: pick "warlock" as the frontend. Lich starts Warlock with a launch command
    saved with the login (Lich's login window shows these as "stormfront" with a custom
    launch). Chrono fills the command in from a login that already uses Warlock, or with
    Lich's standard one; if Warlock isn't found when you log in, put the full path to
    Warlock in the "Warlock command" box. A character saved for Warlock and for another
    frontend logs in with Warlock.
  Settings tab: change the Lich folder, open the log folder, rebuild the
    scheduled tasks, check for updates, and "Open Chrono (minimized) when I sign in"
    (on Windows this adds Chrono to your startup apps; uninstalling removes it).
  Chrono remembers which characters you ticked and your start scripts for next time.
  "About Chrono" (bottom right) shows the version and what Chrono does.

UPDATES
  When Chrono opens, it checks GitHub for a newer version. If there is one, a bar at
  the top offers Download (opens the release page; run the new installer, your settings
  are kept), Not now, or Skip this version. Turn the check off, or check by hand, on the
  Settings tab. Command line: chrono version / chrono check-update

  Realms: Prime, Shattered and Test. (Platinum is retired; old Platinum logins still
  show up but can't be added.)

SCHEDULES - GOOD TO KNOW
  - On Windows they are scheduled tasks (Task Scheduler, folder "Chrono4Lich");
    on Linux, systemd user timers. Either way they run even when the Chrono window
    is closed.
  - You must be signed in to your desktop, because the game window has to open there.
    On Windows the PC can be asleep (it's woken up), but not shut down.
  - If a scheduled login or logout fails, a pop-up or notification tells you why.
  - A schedule with no logout time is a quick login: once the game confirms a character
    is in, Chrono waits about 45 seconds (enough to count as a login, e.g. for the daily
    reward), then logs it out. Characters that were already online when the schedule
    ran (you're playing them) are left alone. To stay logged in, set a logout time.
  - Only one character per account can be online at a time, so Chrono won't let
    one schedule contain two characters from the same account.
  - Everything is written to the log: Lich5/data/chrono/chrono.log

REWARDS
  - Tick "Claim rewards automatically every day at", pick a time, click Save. Chrono
    picks a random evening time to start with, so not everyone hits Simutronics'
    servers at once; change it if you like.
  - SimuCoins (on for every account unless you untick it): your subscription bonus is
    offered once a month. Chrono checks the store every day and presses Claim when it's
    offered. "Next Subscription Bonus..." just means it isn't due yet. If the computer
    was off at the scheduled time, the run happens as soon as it's back on.
  - Daily login rewards (off unless you tick it, per account): Chrono briefly logs in
    each Prime character on the account, collects the reward, and quits. Don't turn this
    on for an account you might be playing at that time: a character online somewhere
    Chrono didn't start would be disconnected. If a character Chrono started is online,
    that account's daily logins are skipped that day.
  - "Claim now" runs it right away; "Claim now for selected" does one account.
  - "History..." lists everything this computer has claimed or tried, newest first,
    with the last date SimuCoins were actually claimed for each account. (Accounts that
    claim on GitHub: GitHub keeps those results; the History window links there.)
  - Results show in the Last result column and in chrono.log. A scheduled run that
    fails shows a pop-up (Windows) or notification (Linux) saying why.
  - The computer has to be on at the scheduled time, unless the account claims on
    GitHub (below).
  - This works the same way as elanthia-online's simu-rewards (by Ondreian):
    https://github.com/elanthia-online/simu-rewards - with no setup beyond ticking a box.

CLAIMING ON GITHUB (works while the computer is off)
  - You need a free GitHub account (github.com). Nothing else to install or set up.
  - On the Rewards tab, tick "Claim on GitHub" for the accounts GitHub should claim,
    then click "Set up GitHub...". Chrono shows a short code and opens GitHub's sign-in
    page; enter the code there and click Authorize.
  - Chrono then, on your GitHub account: creates a private repository called
    chrono4lich-rewards, stores those accounts' logins in it as encrypted secrets
    (encrypted on this computer; only GitHub can decrypt them, to run the claim), writes
    a daily workflow that uses simu-rewards, and starts a first run. "Open results on
    GitHub" shows how each run went.
  - Each account claims either here or on GitHub, never both.
  - Chrono doesn't keep the GitHub sign-in. You sign in again only to change something.
    The Rewards tab says "NEEDS UPDATING" when that's needed: after changing which
    accounts claim on GitHub, the daily-login setting or time, or a saved password.
  - GitHub runs on UTC time, so the run time shifts by an hour when daylight saving time
    starts or ends. GitHub's own timer also often starts runs late, sometimes by hours,
    and busiest at the top of the hour: pick an odd time like 3:23, or use exact timing.
  - A claim that fails (for example Simutronics' servers answering "internal server
    error") is tried again 5 minutes later, then 15 minutes later. Claiming twice is
    harmless. Only one run happens at a time.
  - After the first setup, updating GitHub doesn't start a run; the next one is at the
    scheduled time.
  - GitHub can't tell whether you're playing, so daily login rewards on GitHub always
    run (simu-rewards logs each Prime character in briefly). Leave daily logins off for
    an account you might be playing at that time.

EXACT TIMING FOR GITHUB (optional, free)
  - "Exact timing..." on the Rewards tab makes a free cron-job.org account start the GitHub
    run at your chosen time each day (GitHub starts those within a minute). GitHub's own
    schedule stays on as a backup about 3 hours later, and only claims if that day's run
    didn't succeed.
  - You need: a free cron-job.org account and a GitHub token. Chrono opens GitHub's token
    page with everything filled in except one setting GitHub can't fill in: under
    "Repository access" choose "Only select repositories" and pick only
    chrono4lich-rewards, then "Generate token". That token can only start runs in that one
    repository; it can't read your logins. Then on cron-job.org: Settings, create an API key.
  - Chrono uses the API key to create the job, then forgets it, and never keeps the token
    (it lives in the cron-job.org job). After changing the claim time, the Rewards tab says
    exact timing NEEDS UPDATING: click "Exact timing..." and paste the API key again.
  - cron-job.org emails you if GitHub refuses to start a run (for example, the token was
    deleted).
  - To turn it off: "Exact timing..." again. Then delete the token on GitHub (your picture >
    Settings > Developer settings > Personal access tokens > Fine-grained tokens).
  - Command line: chrono exact-setup / chrono exact-stop

  - "Stop using GitHub..." turns the daily run off and deletes the stored logins; those
    accounts go back to claiming on this computer. The repository itself stays on GitHub
    (delete it there from the repository's Settings if you like). Uninstalling Chrono
    does NOT stop GitHub, so click "Stop using GitHub..." first.

COMMAND LINE (optional)
  Windows: open a Command Prompt in the Chrono4Lich folder. Linux: any terminal.
    chrono list
    chrono login Name1 Name2
    chrono status
    chrono logout all
    chrono config
    chrono add-login ACCOUNT        (asks for the password, then which characters)
    chrono change-password ACCOUNT
    chrono remove-login Name
    chrono rewards                  (settings and last results)
    chrono rewards-set on 20:17     (or: off;  ACCOUNT coins on|off;  ACCOUNT daily on|off)
    chrono run-rewards [ACCOUNT]    (claim now)
    chrono rewards-set ACCOUNT where github|pc
    chrono github-setup             (sign in and set up / update GitHub)
    chrono github-stop
    chrono exact-setup              (cron-job.org starts the GitHub run on time)
    chrono exact-stop
  A name can include its realm, e.g. Name:shattered.

UPDATING, MOVING OR A NEW RUBY
  Windows setup.exe or Linux install.sh: just run the new one. Your Lich folder and
  schedules are kept, and the scheduled tasks are updated for you.
  Windows zip: run install.bat again, then open Chrono and click "Rebuild scheduled
  tasks" on the Settings tab.

COMING FROM LICHSCHED
  Log your characters out before installing Chrono. A character still online from
  lichsched can't be logged out by Chrono; if that happens, Chrono tells you, and you
  type QUIT in the game for that character. Chrono brings your schedules over the
  next time it opens.

UNINSTALL
  Windows setup.exe: use "Add or remove programs" in Windows Settings, or
  "Uninstall Chrono" in the Start menu. This also removes the scheduled tasks.
  Linux: run ~/.local/share/Chrono4Lich/uninstall.sh
  Windows zip: delete each schedule on the Schedules tab (this removes its tasks),
  then delete the Chrono4Lich folder and the desktop shortcut.
  Your schedules stay saved in Lich's data folder, so if you reinstall, "Rebuild
  scheduled tasks" brings them back. Optional cleanup: delete
  Lich5/scripts/chrono_helper.lic and the folder Lich5/data/chrono.

PRIVACY AND PASSWORDS
  - Logging in and out: Chrono reads only character and account names. Lich itself
    does the actual login with its saved password.
  - Adding a login or changing a password: the password you type is sent only to
    Simutronics' own login service (eaccess.play.net, encrypted) to check it and list
    your characters, then saved into Lich's saved logins:
      newer Lich (entry.yaml): saved by Lich itself, with whatever password encryption
        you chose in Lich;
      older Lich (entry.dat): saved the same way Lich and elogin save it.
  - Claiming rewards: Chrono reads each account's saved password (for encrypted
    entry.yaml, by asking Lich's own code to decrypt it), keeps it in memory for that
    run only, and sends it only to Simutronics: the SimuCoin store (store.play.net) and
    the login service (eaccess.play.net), both encrypted.
  - Claiming on GitHub (only if you set it up): the logins for the accounts you chose are
    encrypted on this computer with your repository's public key and stored as GitHub
    secrets in your private repository. Chrono never keeps your GitHub sign-in.
  - Exact timing (only if you set it up): your cron-job.org job holds a GitHub token that
    can only start runs in chrono4lich-rewards. Chrono keeps neither that token nor your
    cron-job.org API key.
  - Update check (on unless you turn it off on the Settings tab): when Chrono opens it asks
    GitHub (api.github.com) for the newest Chrono release. Nothing about you is sent.
  - Chrono never shows passwords, never writes them to its log, and never sends them
    anywhere except Simutronics.
  - Before changing your saved logins, Chrono backs them up to
    Lich5/data/chrono/backups (the last 10 changes).

CREDITS
  Chrono is by Peggyanne. It was inspired by, and works alongside, other players' work:
  - simu-rewards by Ondreian (github.com/elanthia-online/simu-rewards): Chrono's reward
    claiming works the same way, and "Claim on GitHub" runs it.
  - Lich5's account manager by OSXLich-Doug: Chrono's Logins tab is modeled on it.
  - Lich5 by Elanthia Online (github.com/elanthia-online/lich-5): Chrono drives Lich and
    uses its saved logins.
  - elogin.lic, which inspired the original version.

PLAY BY THE RULES
  Logging in on a timer is just starting the game. Scripts that play while you
  are away from the keyboard are covered by Simutronics' policy on unattended
  scripting.
