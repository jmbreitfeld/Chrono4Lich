#!/usr/bin/env bash
# Builds Chrono's downloads into dist/:
#   Chrono4Lich-setup-VERSION.exe  Windows installer (needs makensis: apt install nsis)
#   Chrono4Lich.zip                Windows, without the installer
#   Chrono4Lich-linux.tar.gz       Linux
#   Chrono4Lich-mac.tar.gz         Mac (same files as Linux)
#   bash build.sh 1.10.0
#
# release-signing.pub (the public half of the release-signing key, see tools/make_release_key.rb)
# is built into chrono_update.rb, so the copies built here only accept updates signed with that key.
# Without it the build still works, but those copies can't update themselves.
#
# Builds are reproducible: the same source gives byte-identical zip and tar files (file dates are
# set from the last commit, or SOURCE_DATE_EPOCH).
set -euo pipefail
VERSION="${1:?usage: bash build.sh VERSION}"
cd "$(dirname "$0")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.10.0 (got '$VERSION')"; exit 1; }
FILES=(chrono.rb chrono_config.rb chrono_schedule.rb chrono_eaccess.rb chrono_logins.rb chrono_rewards.rb
       chrono_lich_passwords.rb chrono_github.rb chrono_cronjob.rb chrono_update.rb chrono_sealedbox.rb chrono_gui.rbw chrono_helper.lic chrono.png)
rm -rf dist build && mkdir -p dist build/win/Chrono4Lich build/linux/Chrono4Lich

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || date +%s)}"
export TZ=UTC

# Chrono shows its version (About, update check): stamp this release's version into it
sed -i.bak "s/^CHRONO_VERSION = .*/CHRONO_VERSION = '$VERSION'/" chrono.rb && rm -f chrono.rb.bak  # (-i.bak: GNU and Mac sed both take it)
grep -q "^CHRONO_VERSION = '$VERSION'" chrono.rb || { echo "couldn't set the version in chrono.rb"; exit 1; }

# The release key, into the copies being built (the source keeps it empty)
KEY=""
if [ -f release-signing.pub ]; then
  KEY="$(tr -d ' \r\n' < release-signing.pub)"
  [[ "$KEY" =~ ^[A-Za-z0-9+/]+=*$ ]] || { echo "release-signing.pub doesn't look like a key"; exit 1; }
else
  echo "warning: no release-signing.pub, so these copies of Chrono won't be able to update themselves"
fi
stamp_key() {
  [ -n "$KEY" ] || return 0
  sed -i.bak "s|^  RELEASE_KEY = .*|  RELEASE_KEY = '$KEY'|" "$1/chrono_update.rb" && rm -f "$1/chrono_update.rb.bak"
  grep -q "^  RELEASE_KEY = '$KEY'" "$1/chrono_update.rb" || { echo "couldn't put the release key in $1"; exit 1; }
}

# fixed dates and order, so the same source always gives the same files
settle() { find "$1" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +; }
pack_tar() { # folder-holding-Chrono4Lich output
  (cd "$1" && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_DATE_EPOCH" -cf - Chrono4Lich) | gzip -n -9 > "$2"
}

# Windows zip (README with Windows line endings)
cp "${FILES[@]}" chrono.ico build/win/Chrono4Lich/
for f in README.txt install.bat; do sed 's/\r$//; s/$/\r/' "$f" > "build/win/Chrono4Lich/$f"; done # (cmd needs CRLF in .bat)
stamp_key build/win/Chrono4Lich
settle build/win
(cd build/win && find Chrono4Lich | LC_ALL=C sort | zip -qX ../../dist/Chrono4Lich.zip -@)

# Linux
cp "${FILES[@]}" README.txt install.sh uninstall.sh build/linux/Chrono4Lich/
chmod 644 build/linux/Chrono4Lich/*
chmod 755 build/linux/Chrono4Lich/*.sh
stamp_key build/linux/Chrono4Lich
settle build/linux
pack_tar build/linux dist/Chrono4Lich-linux.tar.gz
# Mac: the same files and install.sh (it detects the Mac), under a name Mac players will look for
cp dist/Chrono4Lich-linux.tar.gz dist/Chrono4Lich-mac.tar.gz

# Windows installer (from the stamped copies in build/win)
makensis -V2 -DVERSION="$VERSION" -DSRC=build/win/Chrono4Lich Chrono4Lich.nsi
mv "Chrono4Lich-setup-$VERSION.exe" dist/
ls -l dist
