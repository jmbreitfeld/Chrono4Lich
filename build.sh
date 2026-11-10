#!/usr/bin/env bash
# Builds Chrono's downloads into dist/:
#   Chrono4Lich-setup-VERSION.exe  Windows installer (needs makensis: apt install nsis)
#   Chrono4Lich.zip                Windows, without the installer
#   Chrono4Lich-linux.tar.gz       Linux
#   ./build.sh 1.6.1
set -euo pipefail
VERSION="${1:?usage: ./build.sh VERSION}"
cd "$(dirname "$0")"
FILES=(chrono.rb chrono_config.rb chrono_schedule.rb chrono_eaccess.rb chrono_logins.rb chrono_rewards.rb
       chrono_lich_passwords.rb chrono_github.rb chrono_cronjob.rb chrono_sealedbox.rb chrono_gui.rbw chrono_helper.lic chrono.png)
rm -rf dist build && mkdir -p dist build/win/Chrono4Lich build/linux/Chrono4Lich

# Windows zip (README with Windows line endings)
cp "${FILES[@]}" chrono.ico install.bat build/win/Chrono4Lich/
sed 's/\r$//; s/$/\r/' README.txt > build/win/Chrono4Lich/README.txt
(cd build/win && zip -qr ../../dist/Chrono4Lich.zip Chrono4Lich)

# Linux
cp "${FILES[@]}" README.txt install.sh uninstall.sh build/linux/Chrono4Lich/
chmod 755 build/linux/Chrono4Lich/*.sh
(cd build/linux && tar czf ../../dist/Chrono4Lich-linux.tar.gz Chrono4Lich)

# Windows installer
makensis -V2 -DVERSION="$VERSION" Chrono4Lich.nsi
mv "Chrono4Lich-setup-$VERSION.exe" dist/
ls -l dist
