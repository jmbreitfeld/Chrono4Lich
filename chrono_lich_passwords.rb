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
  def self.log(*) = nil

  module Util
    def self.install_gem_requirements(gems)
      gems.each_key { |g| require g }
    end
  end
end

$LOAD_PATH.unshift File.join(lich_dir, 'lib')
require 'json'
require 'yaml'
require File.join(lich_dir, 'lib', 'common', 'authentication', 'entry_store')

entries = Lich::Common::Authentication::EntryStore.load_saved_entries(DATA_DIR, false)
result_out.write("CHRONO-PASSWORDS-BEGIN\n")
result_out.write(JSON.generate(entries.to_h { |e| [e[:user_id].to_s.upcase, e[:password].to_s] }))
result_out.write("\nCHRONO-PASSWORDS-END\n")
result_out.flush
