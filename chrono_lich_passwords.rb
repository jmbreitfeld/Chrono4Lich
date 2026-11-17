# chrono_lich_passwords.rb - run by Chrono, with Lich's Ruby, only when Lich's saved logins
# (entry.yaml) have encrypted passwords. Loads Lich's own saved-login code, which decrypts them
# the same way Lich does (including a master password from the system keychain), and writes
# {account => password} as JSON to standard output, which Chrono reads through a pipe.
# Nothing is written to disk or logged.
#
#   ruby chrono_lich_passwords.rb LICH_FOLDER
#
# Lich's code may print its own messages. Those are sent to standard error, so only the
# result (between the BEGIN/END markers) appears on standard output.

result_out = $stdout.dup
result_out.binmode # Windows would otherwise turn "\n" into "\r\n"
$stdout.reopen($stderr)

lich_dir = ARGV.fetch(0)
LICH_DIR = lich_dir
DATA_DIR = File.join(lich_dir, 'data')
TEMP_DIR = File.join(lich_dir, 'temp')

# The few pieces of Lich that its saved-login code expects to exist.
module Lich
  # Lich's code reports problems (e.g. "Error loading YAML entry file: ...") only through its log,
  # then carries on with nothing. Pass those messages to Chrono on standard error, so it can say why.
  def self.log(msg) = $stderr.puts("LICH-LOG #{msg}")

  module Util
    def self.install_gem_requirements(gems)
      gems.each_key { |g| require g }
    end
  end
end

$LOAD_PATH.unshift File.join(lich_dir, 'lib')
require 'json'
require 'yaml'
store = File.join(lich_dir, 'lib', 'common', 'authentication', 'entry_store.rb')
# Chrono uses this part of Lich directly, so a Lich that has changed it is reported plainly
# rather than failing in some odd way.
unsupported = lambda do |why|
  ver = (File.read(File.join(lich_dir, 'lib', 'version.rb'))[/LICH_VERSION\s*=\s*['"]([^'"]+)/, 1] rescue nil)
  $stderr.puts "LICH-LOG error: This Lich (#{ver || 'unknown version'}) has no saved-login code Chrono knows how to use (#{why}). " \
               'Check for a Chrono update.'
  exit 3
end
unsupported.call('lib/common/authentication/entry_store.rb is missing') unless File.exist?(store)
require store
unless defined?(Lich::Common::Authentication::EntryStore) &&
       Lich::Common::Authentication::EntryStore.respond_to?(:load_saved_entries)
  unsupported.call('EntryStore.load_saved_entries is missing')
end

entries = Lich::Common::Authentication::EntryStore.load_saved_entries(DATA_DIR, false)
result_out.write("CHRONO-PASSWORDS-BEGIN\n")
result_out.write(JSON.generate(entries.to_h { |e| [e[:user_id].to_s.upcase, e[:password].to_s] }))
result_out.write("\nCHRONO-PASSWORDS-END\n")
result_out.flush
