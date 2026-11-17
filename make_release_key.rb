# make_release_key.rb - makes Chrono's release-signing key. Run once, by the person who publishes
# Chrono, on their own computer:
#
#   ruby make_release_key.rb      (or double-click it)
#
# It writes two files next to this script:
#   release-signing-key.txt  SECRET. Paste its whole contents into a GitHub Actions secret named
#                            CHRONO_RELEASE_KEY (repo > Settings > Secrets and variables > Actions >
#                            New repository secret), then delete this file. Never upload or share it.
#   release-signing.pub      Public. Upload it to the top of the Chrono4Lich repository. build.sh
#                            builds it into Chrono, which then only accepts updates signed with the key.
#
# Making a new key later means copies of Chrono built with the old one can no longer update
# themselves (players would download the next version from the release page once).

require 'openssl'

dir = __dir__
secret = File.join(dir, 'release-signing-key.txt')
public = File.join(dir, 'release-signing.pub')
# Double-clicked, the window would close before the instructions could be read.
def finish(msg = nil)
  puts msg if msg
  puts
  print 'Press Enter to close this window.'
  $stdin.gets rescue nil
  exit
end

finish("#{secret} already exists, so no new key was made. (Delete it first only if you really want a new key.)") if File.exist?(secret)

key = OpenSSL::PKey.generate_key('ED25519')
File.open(secret, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(key.private_to_pem) }
File.write(public, [key.public_to_der].pack('m0') + "\n")

# check the pair works the way Chrono will use it
test = 'Chrono release key check'
raise 'The new key failed its own check.' unless OpenSSL::PKey.read(key.public_to_der).verify(nil, key.sign(nil, test), test)

puts "Made #{File.basename(secret)} (SECRET) and #{File.basename(public)} (public) in #{dir}."
puts
puts '1. On GitHub: Chrono4Lich > Settings > Secrets and variables > Actions > New repository secret.'
puts '   Name: CHRONO_RELEASE_KEY   Secret: everything in release-signing-key.txt. Save.'
puts '2. Delete release-signing-key.txt (or keep it offline, e.g. on a USB stick, as a backup).'
puts '3. Upload release-signing.pub to the top of the Chrono4Lich repository.'
finish
