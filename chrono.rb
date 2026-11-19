# chrono.rb - command-line login/logout for one or more Lich5 characters
# (also loaded by chrono_gui.rbw for its helpers)
#
# Usage (run with the same Ruby that runs Lich, or through chrono.bat):
#   chrono list
#   chrono status
#   chrono login  Name [Name2 ...] [--realm prime|platinum|shattered] [--scripts a,b] [--timeout 120] [--gap 2]
#   chrono logout Name [Name2 ...] | all   [--timeout 90]
#   chrono kill   Name        (force-closes Lich; character may stay linkdead in game)
#   chrono config             (shows which Lich folder and Ruby are used)
#   chrono set-lich-dir "C:\path\to\Lich5"
#   chrono set-dr-lich-dir "C:\path\to\Lich5-DR"   (only if DragonRealms uses another Lich; "same" undoes it)
#
# A name can carry its realm, e.g. Peggyanne:platinum. Without one, the realm is
# found from entry.dat; --realm is only needed when a name is saved in more than one realm.
# DragonRealms realms are dr, dr-platinum, dr-fallen and dr-test (e.g. Peggyanne:dr).
#
# chrono_helper.lic (kept next to this file) is copied into the Lich scripts folder
# automatically whenever it's missing or out of date.

require 'json'
require 'fileutils'
require 'rbconfig'
require 'time'
require 'etc'

# Chrono's version. The GitHub release build stamps the release's version here.
CHRONO_VERSION = '1.11.1'
require 'optparse'
require_relative 'chrono_config'

begin
  LICH_DIR = ChronoConfig.lich_dir
  LICH_DIR_PROBLEM = LICH_DIR ? nil : 'Chrono doesn\'t know where Lich is installed yet.'
rescue RuntimeError => e
  LICH_DIR = nil
  LICH_DIR_PROBLEM = e.message
end
DATA_DIR   = LICH_DIR && File.join(LICH_DIR, 'data')
SCRIPT_DIR = LICH_DIR && File.join(LICH_DIR, 'scripts')
STATE_DIR  = LICH_DIR && File.join(DATA_DIR, 'chrono')

# Chrono's own folder (Lich5/data/chrono): its log, settings, and backups of Lich's saved logins.
# On Linux and Mac only the player's own account may open it (0700, files 0600). On Windows it
# keeps the Lich folder's permissions, which are already the player's own.
def ensure_state_dir
  FileUtils.mkdir_p(STATE_DIR)
  return if $chrono_state_dir_ready || Gem.win_platform?

  $chrono_state_dir_ready = true
  File.chmod(0o700, STATE_DIR)
  Dir.glob(File.join(STATE_DIR, '**', '*')).each do |f|
    next if File.symlink?(f)
    File.chmod(File.directory?(f) ? 0o700 : 0o600, f)
  rescue SystemCallError
    nil
  end
rescue SystemCallError
  nil
end

# DragonRealms characters log in through the Lich folder used for DragonRealms: the same one as
# GemStone's unless a separate one is set. Their saved logins and helper files are kept there.
# Chrono's own files (schedules, log, settings) stay in the GemStone folder's data/chrono.
begin
  DR_LICH_DIR = LICH_DIR && ChronoConfig.dr_lich_dir(LICH_DIR)
  DR_LICH_DIR_PROBLEM = nil
rescue RuntimeError => e
  DR_LICH_DIR = nil
  DR_LICH_DIR_PROBLEM = e.message
end
DR_STATE_DIR = DR_LICH_DIR && File.join(DR_LICH_DIR, 'data', 'chrono')

require_relative 'chrono_eaccess'
require_relative 'chrono_logins'
HELPER     = 'chrono_helper'
HEARTBEAT_STALE = 45 # seconds
ACK_TIMEOUT     = 20 # seconds for the helper to pick up a logout request

# realm => [game code in entry.dat, lich.rbw flags that pick that game]
REALMS = {
  'prime'       => ['GS3', ['--gemstone']],
  'platinum'    => ['GSX', ['--gemstone', '--platinum']],
  'shattered'   => ['GSF', ['--gemstone', '--shattered']],
  'test'        => ['GST', ['--gemstone', '--test']],
  'dr'          => ['DR',  ['--dragonrealms']],
  'dr-platinum' => ['DRX', ['--dragonrealms', '--platinum']],
  'dr-fallen'   => ['DRF', ['--dragonrealms', '--fallen']],
  'dr-test'     => ['DRT', ['--dragonrealms', '--test']]
}.freeze
GAME_TO_REALM = REALMS.map { |realm, (code, _)| [code, realm] }.to_h

def dr_code?(game_code) = game_code.to_s.upcase.start_with?('DR')
def dr_realm?(realm) = realm.to_s.downcase.start_with?('dr')

# The Lich folder for a game code (nil for DragonRealms when its saved folder is gone).
def lich_dir_for(game_code) = dr_code?(game_code) ? DR_LICH_DIR : LICH_DIR

# The Lich folders that hold saved logins: GemStone's, and DragonRealms' when it's another one.
def lich_folders = [LICH_DIR, DR_LICH_DIR].compact.uniq

class Fail < StandardError; end

def fail!(msg)
  raise Fail, msg
end

ERRORS_SEEN = [] # every error logged this run, for the --notify pop-up

def log(msg, io = $stdout)
  line = "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}  #{msg}"
  if STATE_DIR
    ensure_state_dir
    File.open(File.join(STATE_DIR, 'chrono.log'), 'a', 0o600) { |f| f.puts line }
  end
  ERRORS_SEEN << msg.sub(/\A!!! /, '') if io == $stderr
  begin
    io.puts line
  rescue IOError, SystemCallError
    nil # no console (scheduled run under rubyw); the log file above has it
  end
end

# Pop-up for scheduled runs, so a failure at 6 AM isn't silent.
def notify_box(title, text)
  return notify_mac(title, text) if ChronoConfig.mac?
  return notify_linux(title, text) unless Gem.win_platform?
  begin
    require 'fiddle'
  rescue LoadError
    return nil # (no pop-up without Fiddle; chrono.log still has the details)
  end
  box = Fiddle::Function.new(Fiddle.dlopen('user32')['MessageBoxW'],
                             [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
                             Fiddle::TYPE_INT)
  wtext  = "#{text}\0".encode('UTF-16LE')
  wtitle = "#{title}\0".encode('UTF-16LE')
  box.call(Fiddle::NULL, wtext, wtitle, 0x10 | 0x10000 | 0x40000) # error icon, foreground, topmost
end

# Mac: an alert that stays until dismissed (title and text passed as arguments, not code).
def notify_mac(title, text)
  pid = Process.spawn('osascript', '-e', 'on run argv', '-e',
                      'display alert (item 1 of argv) message (item 2 of argv) as critical', '-e', 'end run',
                      title, text, in: File::NULL, out: File::NULL, err: File::NULL)
  Process.detach(pid)
rescue SystemCallError => e
  log "Could not show an alert: #{e.message}", $stderr
end

# Linux: a desktop notification that stays until dismissed; zenity as a fallback.
def notify_linux(title, text)
  tools = [
    ['notify-send', '--urgency=critical', '--app-name=Chrono', title, text],
    ['zenity', '--error', '--no-wrap', "--title=#{title}", "--text=#{text}"]
  ]
  tools.each do |cmd|
    next unless system('sh', '-c', "command -v #{cmd.first} >/dev/null 2>&1")
    pid = Process.spawn(*cmd, in: File::NULL, out: File::NULL, err: File::NULL)
    Process.detach(pid)
    return
  end
  log 'Could not show a notification: neither notify-send nor zenity is installed.', $stderr
end

# ---------- saved logins ----------

# Saved logins without passwords, from entry.yaml (newer Lich) or entry.dat (older Lich).
def load_entries
  unless SavedLogins.any_saved?
    fail! "No saved logins in #{ChronoConfig.disp(DATA_DIR)} yet. Add them on Chrono's Logins tab " \
          '(or "chrono add-login ACCOUNT"), or save them in Lich\'s login window.'
  end
  SavedLogins.entries
end

def realm_of(entry)
  GAME_TO_REALM[entry[:game_code]] || entry[:game_code].to_s
end

# How Chrono follows a saved login's character: "Name" for GemStone (as it always has), and
# "Name:realm" for DragonRealms, whose helper files are in the DragonRealms Lich folder.
def who_of(entry)
  dr_code?(entry[:game_code]) ? "#{entry[:char_name]}:#{realm_of(entry)}" : entry[:char_name].to_s
end

# Sort key for lists of characters: GemStone first, then DragonRealms, each by game and name.
def game_order(entry)
  [dr_code?(entry[:game_code]) ? 1 : 0, entry[:game_code].to_s, entry[:char_name].to_s]
end

# The same for a typed "Name" or "Name:realm". A name without a realm that's saved only for
# DragonRealms means that DragonRealms character.
def who_from_spec(spec)
  name, realm = spec.to_s.split(':', 2)
  name = name.to_s.capitalize
  if realm.nil?
    saved = (SavedLogins.entries rescue []).select { |e| e[:char_name].to_s.casecmp?(name) }
    return who_of(saved.first) if !saved.empty? && saved.all? { |e| dr_code?(e[:game_code]) }
  end
  dr_realm?(realm) ? "#{name}:#{realm.downcase}" : name
end

# spec is "Name" or "Name:realm"
def resolve_entry(entries, spec, default_realm)
  name, realm = spec.split(':', 2)
  realm = (realm || default_realm)&.downcase
  if realm && !REALMS.key?(realm)
    fail! "Unknown realm '#{realm}' for #{name}. Use #{REALMS.keys.join(', ')}."
  end
  matches = entries.select { |d| d[:char_name].to_s.casecmp?(name) }
  fail! "#{name} isn't in your saved logins. Run 'list' to see them, or add it on the Logins tab." if matches.empty?
  realms = matches.map { |m| realm_of(m) }.uniq
  if realm
    fail! "#{name} is saved, but not for #{realm} (saved for: #{realms.join(', ')})." unless realms.include?(realm)
  elsif realms.size > 1
    fail! "#{name} is saved in more than one realm (#{realms.join(', ')}). " \
          "Write it as #{name}:#{realms.first}, for example."
  else
    realm = realms.first
  end
  same_realm = matches.select { |m| realm_of(m) == realm }
  # The same character saved more than once (e.g. once per frontend) is fine if it's
  # the same account. Lich's --login picks the entry itself.
  accounts = same_realm.map { |m| m[:user_id].to_s.downcase }.uniq
  if accounts.size > 1
    fail! "#{name} (#{realm}) is saved more than once under different accounts (#{accounts.join(', ')}). " \
          "Remove the wrong one in Lich's login window."
  end
  same_realm.first
end

# ---------- status files written by the helper ----------

# who is "Name" or "Name:realm" (see who_of). The helper writes Name.status.json for GemStone and
# Name.dr.status.json for DragonRealms, in the data/chrono folder of the Lich it runs in, so a
# GemStone and a DragonRealms character with the same name never share a file.
def helper_file(who, ext)
  name, realm = who.to_s.split(':', 2)
  dr = dr_realm?(realm)
  dir = dr ? DR_STATE_DIR : STATE_DIR
  fail! "Chrono can't find the DragonRealms Lich folder: #{DR_LICH_DIR_PROBLEM}" unless dir
  File.join(dir, "#{name.capitalize}#{dr ? '.dr' : ''}.#{ext}")
end

def status_path(who) = helper_file(who, 'status.json')
def cmd_path(who) = helper_file(who, 'cmd')

def read_status(name)
  path = status_path(name)
  return nil unless File.exist?(path)
  attempts = 0
  begin
    JSON.parse(File.read(path))
  rescue Errno::EACCES, Errno::ENOENT, JSON::ParserError
    attempts += 1
    raise if attempts >= 5
    sleep 0.2
    retry
  end
end

# Asks Windows directly whether a process is running and is Ruby (Lich), when it started, and
# its command line. Avoids shelling out to tasklist, which flashes a console window when run from
# the GUI. (Without Fiddle, which some Rubies lack, pid_alive? falls back to tasklist.)
begin
  require 'fiddle' if Gem.win_platform?
rescue LoadError
  nil
end

module WinProc
  K32 = Fiddle.dlopen('kernel32')
  VP = Fiddle::TYPE_VOIDP
  IN = Fiddle::TYPE_INT
  OpenProcess        = Fiddle::Function.new(K32['OpenProcess'], [IN, IN, IN], VP)
  GetExitCodeProcess = Fiddle::Function.new(K32['GetExitCodeProcess'], [VP, VP], IN)
  QueryImageName     = Fiddle::Function.new(K32['QueryFullProcessImageNameW'], [VP, IN, VP, VP], IN)
  GetProcessTimes    = Fiddle::Function.new(K32['GetProcessTimes'], [VP, VP, VP, VP, VP], IN)
  CloseHandle        = Fiddle::Function.new(K32['CloseHandle'], [VP], IN)
  QUERY_LIMITED = 0x1000
  STILL_ACTIVE  = 259
  FILETIME_UNIX_OFFSET = 11_644_473_600 # seconds from 1601 (Windows' clock start) to 1970
  CMDLINE_INFO = 60 # ProcessCommandLineInformation (Windows 8.1 and newer)

  def self.with_process(pid)
    handle = OpenProcess.call(QUERY_LIMITED, 0, pid)
    return nil if handle.null?
    begin
      yield handle
    ensure
      CloseHandle.call(handle)
    end
  end

  # Unix time the process started, or nil.
  def self.start_time(pid)
    with_process(pid) do |handle|
      times = Array.new(4) { Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE) }
      next nil if GetProcessTimes.call(handle, *times).zero?
      times[0][0, 8].unpack1('Q<') / 10_000_000 - FILETIME_UNIX_OFFSET
    end
  rescue StandardError
    nil
  end

  # The process's command line, or nil if Windows won't say.
  def self.command_line(pid)
    @nt_query ||= Fiddle::Function.new(Fiddle.dlopen('ntdll')['NtQueryInformationProcess'], [VP, IN, VP, IN, VP], IN)
    with_process(pid) do |handle|
      need = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
      size = 4096
      text = nil
      2.times do
        buf = Fiddle::Pointer.malloc(size, Fiddle::RUBY_FREE)
        if @nt_query.call(handle, CMDLINE_INFO, buf, size, need).zero?
          # a UNICODE_STRING: its length in bytes, then (after padding) a pointer into buf
          bytes = buf[0, 2].unpack1('S<')
          addr = buf[Fiddle::SIZEOF_VOIDP, Fiddle::SIZEOF_VOIDP].unpack1(Fiddle::SIZEOF_VOIDP == 8 ? 'Q<' : 'L<')
          text = Fiddle::Pointer.new(addr)[0, bytes].force_encoding('UTF-16LE').encode('UTF-8') if bytes.positive? && addr.positive?
          break
        end
        size = need[0, 4].unpack1('L<') + 16 # too small: Windows said how much it needs
        break unless size.between?(17, 65_536)
      end
      text
    end
  rescue StandardError
    nil
  end

  def self.ruby_running?(pid)
    handle = OpenProcess.call(QUERY_LIMITED, 0, pid)
    return false if handle.null? # no such process (or not ours)
    begin
      code = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
      fail! "GetExitCodeProcess failed for PID #{pid}." if GetExitCodeProcess.call(handle, code).zero?
      return false unless code[0, 4].unpack1('L') == STILL_ACTIVE
      buf  = Fiddle::Pointer.malloc(2048, Fiddle::RUBY_FREE)
      size = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
      size[0, 4] = [1024].pack('L')
      fail! "QueryFullProcessImageNameW failed for PID #{pid}." if QueryImageName.call(handle, 0, buf, size).zero?
      path = buf[0, size[0, 4].unpack1('L') * 2].force_encoding('UTF-16LE').encode('UTF-8')
      File.basename(path).match?(/ruby/i)
    ensure
      CloseHandle.call(handle)
    end
  end
end if Gem.win_platform? && defined?(Fiddle)

def pid_alive?(pid)
  return false unless pid.is_a?(Integer) && pid > 0
  return WinProc.ruby_running?(pid) if defined?(WinProc)
  return mac_ruby_running?(pid) if ChronoConfig.mac?
  return linux_ruby_running?(pid) unless Gem.win_platform?
  out = `tasklist /FI "PID eq #{pid}" /NH /FO CSV 2>NUL`
  out.lines.any? do |l|
    cols = l.strip.delete_prefix('"').split('","')
    cols[1].to_i == pid && cols[0] =~ /ruby/i
  end
end

# Linux: the process exists, isn't a finished (zombie) process, and is Ruby.
def linux_ruby_running?(pid)
  stat = File.read("/proc/#{pid}/stat")
  return false if stat.sub(/\A.*\)\s*/m, '').start_with?('Z')
  args = File.binread("/proc/#{pid}/cmdline").split("\0")
  args.first(2).any? { |a| File.basename(a).match?(/\Aruby/) } || args.any? { |a| a.end_with?('lich.rbw') }
rescue Errno::ENOENT, Errno::ESRCH
  false
end

# Mac (no /proc): the process exists, isn't a zombie, and is Ruby or Lich.
def mac_ruby_running?(pid)
  out = IO.popen(['ps', '-p', pid.to_s, '-o', 'stat=', '-o', 'command='], err: File::NULL, &:read).to_s.strip
  return false if out.empty? || out.start_with?('Z')
  stat, program, *args = out.split
  return false unless stat && program
  File.basename(program).start_with?('ruby') || args.any? { |a| a.end_with?('lich.rbw') }
rescue SystemCallError
  false
end

# ---------- is this status file's Lich still the one running? ----------
# A status file outlives a Lich that crashed, and the system may since have given its process ID
# to something else (another character's Lich, or Chrono itself). So a status file's PID only
# counts as that character's Lich if the process started before the helper wrote the file
# ('since': the helper runs inside Lich, so Lich always starts first).

# Unix time a process started, or nil if it can't be told.
def process_start_time(pid)
  return WinProc.start_time(pid) if defined?(WinProc)
  return nil if Gem.win_platform?

  if ChronoConfig.mac?
    out = IO.popen({ 'LC_ALL' => 'C' }, ['ps', '-p', pid.to_s, '-o', 'lstart='], err: File::NULL, &:read).to_s.strip
    return out.empty? ? nil : Time.strptime(out, '%a %b %e %H:%M:%S %Y').to_i
  end
  fields = File.read("/proc/#{pid}/stat").sub(/\A.*\)\s*/m, '').split # from field 3 (state) on
  boot = File.read('/proc/stat')[/^btime (\d+)/, 1].to_i
  boot + fields[19].to_i / Etc.sysconf(Etc::SC_CLK_TCK) # field 22: start time, in ticks after boot
rescue StandardError
  nil
end

# A process's command line as one string, or nil if it can't be told.
def process_command_line(pid)
  return WinProc.command_line(pid) if defined?(WinProc)
  return nil if Gem.win_platform?
  return IO.popen(['ps', '-p', pid.to_s, '-o', 'command='], err: File::NULL, &:read).to_s.strip.then { |s| s.empty? ? nil : s } if ChronoConfig.mac?

  File.binread("/proc/#{pid}/cmdline").split("\0").join(' ')
rescue StandardError
  nil
end

START_SLACK = 2 # seconds of rounding between the system's start time and the helper's clock

# The process started no later than the helper's status file says it did (true if unknown).
def started_in_time?(st)
  since = st['since'].to_i
  return true if since.zero?
  started = process_start_time(st['pid'].to_i)
  started.nil? || started <= since + START_SLACK
end

# The character's Lich is running: the PID is alive, is Ruby, and isn't a reused one.
def lich_alive?(st)
  st && pid_alive?(st['pid']) && started_in_time?(st)
end

# Stricter, before force-closing a process: it must be shown to be this character's Lich.
# Returns nil if it is, or the reason it can't be confirmed.
def not_lich_of(name, st)
  pid = st['pid'].to_i
  return "the process ID #{pid} isn't a running Ruby" unless pid_alive?(pid)
  started = process_start_time(pid)
  since = st['since'].to_i
  if started && since.positive? && started > since + START_SLACK
    return "process #{pid} started after #{name}'s Lich did (#{Time.at(started)} vs #{Time.at(since)}), so it's something else using a reused process ID"
  end
  cmd = process_command_line(pid)
  char = name.to_s.split(':', 2).first # (DragonRealms names carry their realm: Name:dr)
  if cmd
    return "process #{pid} isn't Lich (#{cmd[0, 120]})" unless cmd.include?('lich.rbw')
    # Chrono starts Lich with --login Name. (A Lich started by Saga may not say which character;
    # then the start time above is what tells.)
    login = cmd[/--login[= ]+(\S+)/, 1]
    return "process #{pid} is Lich, but not #{char}'s (--login #{login})" if login && !login.casecmp?(char)
    return "Chrono couldn't confirm that process #{pid} is #{char}'s Lich" if login.nil? && (started.nil? || since.zero?)
  elsif started.nil? || since.zero?
    return "Chrono couldn't confirm that process #{pid} is #{name}'s Lich"
  end
  nil
end

def online?(name)
  st = read_status(name)
  st && st['state'] != 'offline' && lich_alive?(st)
end

def heartbeat_age(st)
  Time.now.to_i - st['heartbeat'].to_i
end

# Status files the helper has written, as {who => path}: "Name" for GemStone, "Name:dr" for
# DragonRealms.
def status_files
  gs = Dir.glob(File.join(STATE_DIR, '*.status.json')).reject { |f| f.end_with?('.dr.status.json') }
                                                       .to_h { |f| [File.basename(f, '.status.json'), f] }
  dr = DR_STATE_DIR ? Dir.glob(File.join(DR_STATE_DIR, '*.dr.status.json')) : []
  gs.merge(dr.to_h { |f| ["#{File.basename(f, '.dr.status.json')}:dr", f] })
end

def online_names
  status_files.keys.select { |n| online?(n) }
end

# ---------- launching ----------

def rubyw_path
  c = RbConfig::CONFIG
  exe = c['RUBYW_INSTALL_NAME'].to_s.empty? ? c['RUBY_INSTALL_NAME'] : c['RUBYW_INSTALL_NAME']
  path = File.join(c['bindir'], exe + c['EXEEXT'])
  fail! "Can't find Ruby at #{path}." unless File.exist?(path)
  path
end

# Print a summary and return true if everything succeeded.
def summarize(action, results)
  return results.values.all?(&:nil?) if results.size <= 1
  puts
  puts "#{action} summary:"
  results.each do |name, err|
    puts format('  %-16s %s', name, err ? "FAILED - #{err}" : 'ok')
  end
  failed = results.count { |_, e| e }
  log "#{action.upcase} SUMMARY: #{results.size - failed} ok, #{failed} failed", failed > 0 ? $stderr : $stdout
  failed.zero?
end

# ---------- commands ----------

def cmd_list
  entries = load_entries
  if entries.empty?
    puts 'No characters are saved yet.'
    return
  end
  puts format('%-16s %-12s %-20s %-16s %s', 'Character', 'Realm', 'Account', 'Frontend', 'Online')
  groups = entries.group_by { |e| [e[:game_code], e[:char_name].to_s.downcase, e[:user_id].to_s.downcase] }
  groups.values.map(&:first).sort_by { |e| game_order(e) }.each do |e|
    fronts = groups[[e[:game_code], e[:char_name].to_s.downcase, e[:user_id].to_s.downcase]].map { |x| x[:frontend] }.uniq
    puts format('%-16s %-12s %-20s %-16s %s', e[:char_name], realm_of(e), e[:user_id], fronts.join(','),
                online?(who_of(e)) ? 'yes' : '')
  end
end

# ---------- saved-login commands ----------
# Passwords are typed at a prompt, never on Chrono's command line. Chrono hands them to Lich on
# standard input (Lich 5.25.0 and newer). Older Lich only takes a password on its own command
# line, where other programs on this PC can see it for the second or two Lich runs.

def ask_password(prompt)
  require 'io/console'
  fail! 'This command needs a terminal to type the password into.' unless $stdin.tty?
  $stdout.print prompt
  pw = $stdin.noecho(&:gets).to_s.chomp
  $stdout.puts
  pw
end

def cmd_add_login(account, frontend)
  fail! 'Use: chrono add-login ACCOUNT [--frontend NAME]' unless account
  password = ask_password("Password for #{account}: ")
  puts 'Asking Simutronics for the characters on this account...'
  chars = ChronoEAccess.list_characters(account, password, data_dir: DATA_DIR, codes: ChronoEAccess::ALL_CODES)
  fail! "Account #{account} has no GemStone or DragonRealms characters in a game it's subscribed to." if chars.empty?
  saved = load_entries rescue []
  chars.each_with_index do |c, i|
    already = saved.any? { |e| e[:char_name].casecmp?(c[:char_name]) && e[:game_code] == c[:game_code] }
    puts format('  %2d) %-16s %-10s%s', i + 1, c[:char_name], GAME_TO_REALM[c[:game_code]] || c[:game_code],
                already ? ' (already saved)' : '')
  end
  $stdout.print 'Which to save? Numbers separated by spaces, or "all": '
  answer = $stdin.gets.to_s.strip.downcase
  picked = answer == 'all' ? chars : answer.split(/[\s,]+/).map { |n| chars[Integer(n) - 1] rescue nil }.compact
  fail! 'Nothing picked, nothing saved.' if picked.empty?
  frontend ||= SavedLogins.frontends.first
  unless SavedLogins.frontends.include?(frontend)
    fail! "Unknown frontend '#{frontend}'. Choose from: #{SavedLogins.frontends.join(', ')}"
  end
  n = SavedLogins.add(account, password, picked, frontend)
  puts "Saved #{n} character(s) with frontend #{frontend}."
  true
end

def cmd_change_password(account)
  fail! 'Use: chrono change-password ACCOUNT' unless account
  password = ask_password("New password for #{account}: ")
  puts 'Checking it with Simutronics...'
  ChronoEAccess.list_characters(account, password, data_dir: DATA_DIR)
  SavedLogins.change_password(account, password)
  puts "Saved the new password for #{account}."
  true
end

# Refuses to remove a saved login that a schedule uses or that's online right now.
def check_removable!(entry)
  spec = "#{entry[:char_name]}:#{realm_of(entry)}"
  in_use = Schedules.load.select { |s| s['characters'].any? { |c| c.casecmp?(spec) } }
  unless in_use.empty?
    fail! "#{entry[:char_name]} is in the schedule(s) #{in_use.map { |s| s['name'] }.join(', ')}. " \
          'Take them out of those schedules first.'
  end
  # (Online is fine: removing a saved login only affects the next login.)
end

def cmd_remove_login(spec)
  fail! 'Use: chrono remove-login Name[:realm]' unless spec
  entry = resolve_entry(load_entries, spec, nil)
  check_removable!(entry)
  SavedLogins.remove(entry[:char_name], entry[:game_code], entry[:user_id])
  puts "Removed #{entry[:char_name]} (#{realm_of(entry)})."
  true
end

def cmd_status
  files = status_files
  if files.empty?
    puts 'No characters have been started by Chrono yet.'
    return
  end
  puts format('%-20s %-14s %-8s %-8s %s', 'Character', 'State', 'PID', 'Process', 'Heartbeat')
  files.sort_by { |who, _| [who.include?(':') ? 1 : 0, who] }.each do |who, f|
    st = JSON.parse(File.read(f))
    alive = lich_alive?(st)
    beat = alive ? "#{heartbeat_age(st)}s ago" : '-'
    puts format('%-20s %-14s %-8s %-8s %s', who, st['state'], st['pid'], alive ? 'running' : 'gone', beat)
    puts "    #{st['detail']}" if st['detail']
  end
end

def check_account_conflicts(entries, selected)
  # Two selected characters on the same account: refuse before launching anything.
  selected.group_by { |e| [e[:game_code], e[:user_id].to_s.downcase] }.each do |(_, acct), group|
    next if group.size < 2
    fail! "#{group.map { |e| e[:char_name] }.join(' and ')} are on the same account (#{acct}). " \
          'Only one can be online at a time, so pick one.'
  end
  # A selected character whose account already has someone else online.
  selected.each do |entry|
    entries.each do |other|
      next if other.equal?(entry) || selected.include?(other)
      next if other[:char_name].to_s.casecmp?(entry[:char_name].to_s) # duplicate save of the same character
      next unless other[:game_code] == entry[:game_code]
      next unless other[:user_id].to_s.casecmp?(entry[:user_id].to_s)
      if online?(who_of(other))
        fail! "#{other[:char_name]} is online on the same account as #{entry[:char_name]} (#{entry[:user_id]}). " \
              "Logging in #{entry[:char_name]} would kick it off. Log #{other[:char_name]} out first."
      end
    end
  end
end

# A character saved both for Warlock and for another frontend: Lich would pick one of them
# itself, so ask it for the Warlock one. (With only one saved login, nothing extra is needed.)
def warlock_flag(entry)
  same = (load_entries rescue []).select do |e|
    e[:char_name].to_s.casecmp?(entry[:char_name].to_s) && e[:game_code] == entry[:game_code]
  end
  fronts = same.map { |e| e[:frontend] }.uniq
  fronts.include?(SavedLogins::WARLOCK) && fronts.size > 1 ? ['--custom-launch=warlock'] : []
end

# Starts Lich for one character and returns its PID; doesn't wait for it to come online.
def start_login(entry, scripts)
  name = entry[:char_name]
  realm = realm_of(entry)
  who = who_of(entry)
  lich = lich_dir_for(entry[:game_code])
  fail! "#{name} is already online (Lich PID #{read_status(who)['pid']})." if online?(who)
  check_saga_lich_folder!(entry)

  [cmd_path(who), status_path(who)].each { |p| File.delete(p) if File.exist?(p) }
  FileUtils.mkdir_p(File.dirname(status_path(who)))
  start_scripts = ([HELPER] + scripts).uniq.join(',')
  args = [rubyw_path, File.join(lich, 'lich.rbw'), *REALMS[realm][1],
          '--login', name, *warlock_flag(entry), "--start-scripts=#{start_scripts}"]

  log "LOGIN  #{name} (#{realm}): starting Lich#{saga_entry?(entry) ? ', which hands the login to Saga' : ''}"
  # Lich must not inherit our stdout/stderr: if they are a pipe (the GUI), Lich would hold
  # it open for as long as the character is online and the GUI would wait forever.
  group = Gem.win_platform? ? { new_pgroup: true } : { pgroup: true }
  # On Linux, a scheduled run is a systemd service, and systemd stops everything the
  # service started once it finishes. Starting Lich in its own scope keeps it running.
  if !Gem.win_platform? && ENV['INVOCATION_ID']
    fail! 'systemd-run is missing, so a scheduled login could not keep Lich running.' unless
      system('sh', '-c', 'command -v systemd-run >/dev/null 2>&1')
    args = ['systemd-run', '--user', '--scope', '--quiet', '--collect',
            "--unit=chrono-lich-#{name.downcase}-#{Time.now.to_i}", *args]
  end
  # Windows hands every inheritable handle to a new process, including the pipe the Chrono
  # window reads this command's output from, even with Lich's own output sent to NUL. Lich
  # keeps running, so the window would wait on that pipe. Mark ours as not to be inherited.
  if Gem.win_platform?
    [$stdout, $stderr].each do |io|
      io.close_on_exec = true
    rescue StandardError, NotImplementedError
      nil
    end
  end
  pid = Process.spawn(*args, chdir: lich, **group,
                      in: File::NULL, out: File::NULL, err: File::NULL)
  LAUNCHERS[pid] = Process.detach(pid)
  pid
end

# ---------- Saga ----------
# Saga logs characters in itself. For a login saved with Saga as its frontend, Lich hands the
# login to Saga (with the character, game and account) and exits; Saga then signs in with the
# login saved in Saga and starts its own Lich for the character. Chrono's helper runs in that
# Lich only if it's in Lich's autostart, and then reports in as usual, so Chrono can see the
# character and log it out. Without it, Chrono can start a Saga login but not follow it.
SAGA_REPORT_WAIT = (ChronoConfig.dev_env('CHRONO_SAGA_WAIT') || 60).to_i # seconds to wait for a Saga login's helper to report in
LAUNCHERS = {} # Lich PID => the thread waiting for it to exit (its status says whether a Saga handoff worked)

# Each game's Lich keeps its own autostart list, so this is typed once per game.
def saga_tracking_hint(dr = false)
  'To let Chrono see Saga logins and log them out, type  ;autostart add --global chrono_helper  ' \
    "once in any #{dr ? 'DragonRealms' : 'GemStone'} game window."
end

def saga_entry?(entry)
  entry[:frontend].to_s.casecmp?('saga') && entry[:custom_launch].to_s.strip.empty?
end

# Saga starts the character's Lich from its own setting: the Lich folder set for that character in
# Saga, or else Saga's default Lich folder. Lich doesn't tell Saga which folder to use. With a Lich
# kept for each game, that setting decides which game's Lich (scripts, settings) the session runs in.
module SagaPrefs
  module_function

  # Saga's settings file (Electron's userData folder for Saga).
  def file
    return ChronoConfig.dev_env('CHRONO_SAGA_PREFS') if ChronoConfig.dev_env('CHRONO_SAGA_PREFS') # (testing only)
    base = if Gem.win_platform? then ENV['APPDATA'] || File.join(Dir.home, 'AppData', 'Roaming')
           elsif RUBY_PLATFORM.include?('darwin') then File.join(Dir.home, 'Library', 'Application Support')
           else ENV['XDG_CONFIG_HOME'] || File.join(Dir.home, '.config')
           end
    File.join(base, 'saga', 'prefs.json')
  end

  # The Lich folder Saga will start this character with, or nil if Chrono can't tell (no Saga
  # settings, or no folder set). Saga keys its per-character folders "account|game|name", in lower case.
  def lich_dir_for(account, game_code, name)
    prefs = JSON.parse(File.read(file))
    return nil unless prefs.is_a?(Hash)

    key = [account, game_code, name].map { |s| s.to_s.strip.downcase }.join('|')
    overrides = prefs['lichDirs'].is_a?(Hash) ? prefs['lichDirs'] : {}
    dir = (overrides[key] || prefs['lichDir']).to_s.strip
    dir.empty? ? nil : dir
  rescue SystemCallError, IOError, JSON::ParserError
    nil
  end

  # Where Saga writes game logs: the log folder set in Saga, or else "logs" next to its settings.
  def logs_dir
    custom = (JSON.parse(File.read(file))['logFolder'] rescue nil).to_s.strip
    custom.empty? ? File.join(File.dirname(file), 'logs') : custom
  end

  def same_folder?(a, b)
    canon =->(d) { (File.realpath(ChronoConfig.normalize(d)) rescue ChronoConfig.normalize(d)) }
    x, y = canon.(a), canon.(b)
    # Mac and Windows folder names ignore case
    Gem.win_platform? || RUBY_PLATFORM.include?('darwin') ? x.casecmp?(y) : x == y
  end
end

# A Saga login that Saga would start with a different Lich than the one Chrono uses for that game
# would run with the wrong scripts and settings (a DragonRealms character in the GemStone Lich, say),
# and Chrono couldn't see it or log it out. Refuse it and say what to change in Saga.
def check_saga_lich_folder!(entry)
  return unless saga_entry?(entry)

  saga_dir = SagaPrefs.lich_dir_for(entry[:user_id], entry[:game_code], entry[:char_name])
  return unless saga_dir # can't tell: carry on, as before

  want = lich_dir_for(entry[:game_code])
  return if want.nil? || SagaPrefs.same_folder?(saga_dir, want)

  game = dr_code?(entry[:game_code]) ? 'DragonRealms' : 'GemStone'
  name = entry[:char_name]
  fail! "Saga would start #{name} with the Lich in #{ChronoConfig.disp(saga_dir)}, but Chrono uses " \
        "#{ChronoConfig.disp(want)} for #{game}, so #{name} would run with the wrong Lich's scripts and settings " \
        "and Chrono couldn't log it out. Not logging in. In Saga, set #{name}'s Lich folder to " \
        "#{ChronoConfig.disp(want)}, then try again."
end

# A Saga login after the Lich that handed it over has exited: nil while waiting for the helper
# in Saga's Lich to report in, :handed once Chrono stops waiting, or raises Fail.
def saga_handoff_progress(entry, pid, started)
  who = who_of(entry)
  dr = dr_code?(entry[:game_code])
  if (waiter = LAUNCHERS.delete(pid))
    unless waiter.value&.success?
      fail! "Lich couldn't hand the login to Saga. Check that Saga is installed and has this account saved, " \
            "and see Lich's debug log in #{File.join(lich_dir_for(entry[:game_code]), 'temp')}."
    end
    log "LOGIN  #{who}: handed to Saga, which logs in with the login saved in Saga"
  end
  return nil if Time.now < started + SAGA_REPORT_WAIT

  log "LOGIN  #{who}: Chrono's helper didn't report in from Saga, so Chrono can't confirm this login " \
      "or log it out (log out in Saga). #{saga_tracking_hint(dr)}#{dr ? dr_saga_folder_note : ''}"
  :handed
end

# Saga's Lich for DragonRealms has to be the folder Chrono uses for DragonRealms, or Chrono looks
# for the helper's reports in the wrong place.
def dr_saga_folder_note
  " (Chrono looks for DragonRealms characters in #{ChronoConfig.disp(DR_LICH_DIR)}; Saga must start them with " \
    "that Lich too: in Saga, set the character's Lich folder to it. Chrono's DragonRealms Lich folder is set " \
    'on the Settings tab.)'
end

# ---------- full-screen Warlock (Windows) ----------
# Warlock picks its own window size, and a window merely sized to the screen still shows Windows'
# invisible resize borders as a small gap. So once a Warlock character is in, Chrono finds its
# window (Warlock titles it "Warlock - Name") and maximizes it, as the maximize button would.
module WarlockWindow
  SW_MAXIMIZE = 3
  WAIT = 25 # seconds to look for the window

  module_function

  def wanted?(entry)
    Gem.win_platform? && entry[:frontend] == SavedLogins::WARLOCK && SavedLogins.maximized?(entry[:custom_launch])
  end

  def user32
    @user32 ||= begin
      require 'fiddle'
      lib = Fiddle.dlopen('user32')
      { find: Fiddle::Function.new(lib['FindWindowW'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP),
        show: Fiddle::Function.new(lib['ShowWindow'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT) }
    end
  end

  # Warlock stays open, disconnected, after its Lich exits. Once a Warlock character's Lich has
  # exited after a logout, close its Warlock too: Mac/Linux by ending what's left of Lich's process
  # group (Warlock is in it), Windows by asking the "Warlock - Name" window to close.
  # who: "Name", or "Name:realm" for DragonRealms (see who_of), so only that game's login counts.
  def close_after_logout(who, lich_pid)
    name, realm = who.to_s.split(':', 2)
    entries = (load_entries rescue [])
    return unless entries.any? do |e|
      e[:char_name].to_s.casecmp?(name) && dr_code?(e[:game_code]) == dr_realm?(realm) && e[:frontend] == SavedLogins::WARLOCK
    end

    if Gem.win_platform?
      require 'fiddle'
      lib = Fiddle.dlopen('user32')
      find = Fiddle::Function.new(lib['FindWindowW'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
      post = Fiddle::Function.new(lib['PostMessageW'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_UINT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      hwnd = find.call(nil, "Warlock - #{name}\0".encode('UTF-16LE'))
      return if hwnd.null?

      post.call(hwnd, 0x0010, nil, nil) # WM_CLOSE, as clicking its X
      log "LOGOUT #{who}: closed Warlock's window"
    else
      Process.kill('TERM', -lich_pid.to_i) # Lich's group; Lich itself is gone
      log "LOGOUT #{who}: closed Warlock"
    end
  rescue Errno::ESRCH, Errno::EPERM
    nil # nothing left in the group
  rescue StandardError, LoadError => e
    log "LOGOUT #{who}: couldn't close Warlock: #{e.message}"
  end

  # Looks for the character's Warlock window for up to WAIT seconds and maximizes it. true if done.
  def maximize(name)
    title = "Warlock - #{name}\0".encode('UTF-16LE')
    deadline = Time.now + WAIT
    while Time.now < deadline
      hwnd = user32[:find].call(nil, title)
      unless hwnd.null?
        user32[:show].call(hwnd, SW_MAXIMIZE)
        log "LOGIN  #{name}: maximized Warlock's window"
        return true
      end
      sleep 0.5
    end
    log "LOGIN  #{name}: didn't find a window titled \"Warlock - #{name}\" to maximize " \
        '(a custom window title set in Warlock would explain it)'
    false
  rescue StandardError, LoadError => e
    log "LOGIN  #{name}: couldn't maximize Warlock's window: #{e.message}"
    false
  end
end

# nil while still logging in, :online, :handed (a Saga login Chrono can't follow), or raises Fail
def login_progress(entry, pid, deadline, timeout, started: Time.now)
  who = who_of(entry)
  st = read_status(who)
  if st && st['state'] == 'online'
    log "LOGIN  #{who}: online (Lich PID #{st['pid']})"
    return :online
  end
  unless pid_alive?(pid)
    return saga_handoff_progress(entry, pid, started) if saga_entry?(entry)

    fail! "Lich exited before #{entry[:char_name]} came online. " \
          "Check Lich's debug log in #{File.join(lich_dir_for(entry[:game_code]), 'temp')}."
  end
  return nil if Time.now < deadline
  fail! "did not report online within #{timeout}s. Lich (PID #{pid}) is still running, " \
        "so the login may be stuck or the helper didn't start. Check that character's game window."
end

def cmd_login(specs, default_realm, scripts, timeout, gap, skip_online: false)
  entries = load_entries
  selected = specs.map { |s| resolve_entry(entries, s, default_realm) }.uniq
  selected.map { |e| e[:game_code] }.uniq.each do |code|
    lich = lich_dir_for(code) or fail! "Chrono can't find the DragonRealms Lich folder: #{DR_LICH_DIR_PROBLEM}"
    fail! "lich.rbw not found at #{File.join(lich, 'lich.rbw')}." unless File.exist?(File.join(lich, 'lich.rbw'))
    ensure_helper!(lich)
  end
  check_account_conflicts(entries, selected)
  ensure_state_dir

  # All characters log in at the same time, like ticking several in Lich's login window:
  # each Lich is started a few seconds after the previous one (so they don't all hit
  # Simutronics' login server and Lich's own files at the same instant), without waiting
  # for the previous one to finish logging in. Then Chrono waits for all of them.
  # Characters are known by who_of ("Name", or "Name:realm" for DragonRealms).
  results = {}
  waiting = {} # who => [pid, deadline, entry, started]
  maximizers = [] # threads maximizing Warlock windows (Windows, full-screen Warlock logins)
  check = lambda do
    waiting.to_a.each do |who, (pid, deadline, entry, started)|
      progress = login_progress(entry, pid, deadline, timeout, started: started)
      next unless progress

      # maximizing waits for the window, so it happens alongside the other logins
      if progress == :online && WarlockWindow.wanted?(entry)
        maximizers << Thread.new { WarlockWindow.maximize(entry[:char_name]) }
      end
      results[who] = nil
      waiting.delete(who)
    rescue Fail => e
      log "!!! LOGIN #{who} FAILED: #{e.message}", $stderr
      results[who] = e.message
      waiting.delete(who)
    end
  end
  launched = 0
  selected.each do |entry|
    who = who_of(entry)
    if skip_online && online?(who)
      log "LOGIN  #{who}: already online, skipped"
      results[who] = nil
      next
    end
    if launched > 0
      gap.times { check.call; sleep 1 }
    end
    launched += 1
    begin
      waiting[who] = [start_login(entry, scripts), Time.now + timeout, entry, Time.now]
    rescue Fail => e
      log "!!! LOGIN #{who} FAILED: #{e.message}", $stderr
      results[who] = e.message
    end
  end
  until waiting.empty?
    check.call
    sleep 1 unless waiting.empty?
  end
  # summary in the order the characters were picked
  maximizers.each(&:join)
  summarize('Login', selected.map { |e| who_of(e) }.select { |n| results.key?(n) }.to_h { |n| [n, results[n]] })
end

def request_logout(name)
  st = read_status(name)
  unless st
    fail! "no status. It wasn't started by Chrono, or the helper never ran. " \
          "(For a Saga login: #{saga_tracking_hint(dr_realm?(name.split(':', 2)[1]))})"
  end
  fail! "Lich process (PID #{st['pid']}) isn't running. Last known state: #{st['state']}." unless lich_alive?(st)
  unless %w[online logout_failed].include?(st['state'])
    fail! "state is '#{st['state']}', not online. If the helper was stopped, restart it with ;#{HELPER} in that character's window."
  end
  if heartbeat_age(st) > HEARTBEAT_STALE
    fail! "helper hasn't checked in for #{heartbeat_age(st)}s. Restart it with ;#{HELPER} in that character's window."
  end
  tmp = cmd_path(name) + '.tmp'
  File.write(tmp, 'logout')
  File.rename(tmp, cmd_path(name))
  log "LOGOUT #{name}: logout requested"
  st
end

def cmd_logout(specs, timeout, skip_offline: false)
  names =
    if specs.map(&:downcase) == ['all']
      online_names.tap { |n| fail! 'No characters started by Chrono are online.' if n.empty? }
    else
      specs.map { |s| who_from_spec(s) }.uniq
    end

  results = {}
  pending = {}
  names.each do |name|
    if skip_offline && !online?(name)
      log "LOGOUT #{name}: already offline, skipped"
      results[name] = nil
      next
    end
    pending[name] = { st: request_logout(name), sent: Time.now }
  rescue Fail => e
    log "!!! LOGOUT #{name} FAILED: #{e.message}", $stderr
    results[name] = e.message
  end

  deadline = Time.now + timeout
  until pending.empty? || Time.now > deadline
    pending.dup.each do |name, info|
      err = nil
      if !lich_alive?(info[:st])
        log "LOGOUT #{name}: logged out"
        WarlockWindow.close_after_logout(name, info[:st]['pid'])
      elsif (cur = read_status(name)) && cur['state'] == 'logout_failed' && !File.exist?(cmd_path(name))
        err = "could not log out. #{cur['detail']}"
      elsif File.exist?(cmd_path(name)) && Time.now - info[:sent] > ACK_TIMEOUT
        File.delete(cmd_path(name))
        err = "helper didn't pick up the logout request within #{ACK_TIMEOUT}s."
      else
        next
      end
      log("!!! LOGOUT #{name} FAILED: #{err}", $stderr) if err
      results[name] = err
      pending.delete(name)
    end
    sleep 1
  end
  pending.each_key do |name|
    err = "still connected after #{timeout}s. Last helper note: #{read_status(name)&.fetch('detail', nil)}"
    log "!!! LOGOUT #{name} FAILED: #{err}", $stderr
    results[name] = err
  end
  summarize('Logout', names.to_h { |n| [n, results[n]] })
end

def cmd_kill(name)
  name = who_from_spec(name)
  st = read_status(name)
  fail! "No status for #{name}." unless st
  fail! "#{name} isn't online (its last state was '#{st['state']}')." if st['state'] == 'offline'
  fail! "#{name}'s Lich process (PID #{st['pid']}) isn't running." unless pid_alive?(st['pid'])
  if (why = not_lich_of(name, st))
    fail! "Not force-closing: #{why}. #{name}'s Lich has probably already exited. " \
          'If a game window is still stuck, close it yourself.'
  end
  log "KILL   #{name}: force-closing Lich PID #{st['pid']} and its frontend. The character may stay linkdead in game."
  if Gem.win_platform?
    ok = system('taskkill', '/PID', st['pid'].to_s, '/T', '/F')
    fail! "taskkill failed for PID #{st['pid']}." unless ok
  else
    kill_linux(st['pid'])
  end
  log "KILL   #{name}: done"
  true
end

# Lich runs in its own process group, so signal the whole group (Lich and its frontend).
def kill_linux(pid)
  target = Process.getpgid(pid) == pid ? -pid : pid
  Process.kill('TERM', target)
  10.times do
    return unless pid_alive?(pid)
    sleep 0.5
  end
  Process.kill('KILL', target)
  sleep 0.5
  fail! "PID #{pid} is still running after a forced kill." if pid_alive?(pid)
rescue Errno::ESRCH
  nil # already gone
rescue Errno::EPERM
  fail! "Not allowed to stop PID #{pid}; it may belong to another user."
end

# ---------- main ----------

# Keeps a Lich folder's copy of the helper the same as the one shipped with Chrono.
def ensure_helper!(lich = LICH_DIR)
  scripts = File.join(lich, 'scripts')
  bundled = File.join(ChronoConfig::APP_DIR, "#{HELPER}.lic")
  target  = File.join(scripts, "#{HELPER}.lic")
  fail! "Lich's scripts folder is missing: #{scripts}" unless File.directory?(scripts)
  if File.exist?(bundled)
    return if File.exist?(target) && File.binread(target) == File.binread(bundled)
    FileUtils.cp(bundled, target)
    log "Installed #{HELPER}.lic into #{scripts}"
  elsif !File.exist?(target)
    fail! "#{HELPER}.lic is missing. It should be in #{ChronoConfig::APP_DIR}, next to chrono.rb."
  end
end

def require_lich_dir!
  return if LICH_DIR
  fail! "#{LICH_DIR_PROBLEM} Open the Chrono window to pick the Lich folder, or run: " \
        "chrono set-lich-dir \"#{ChronoConfig.example_lich_dir}\""
end

def cmd_config
  puts "Lich folder:  #{LICH_DIR ? ChronoConfig.disp(LICH_DIR) : "(not set) #{LICH_DIR_PROBLEM}"}"
  if LICH_DIR
    dr = DR_LICH_DIR ? ChronoConfig.disp(DR_LICH_DIR) : "(not found) #{DR_LICH_DIR_PROBLEM}"
    puts "DragonRealms: #{dr}#{DR_LICH_DIR == LICH_DIR ? ' (the same Lich folder)' : ''}"
  end
  puts "Ruby:         #{ChronoConfig.disp(rubyw_path)}"
  puts "Config file:  #{ChronoConfig.disp(ChronoConfig::CONFIG_FILE)}"
  found = ChronoConfig.detect
  puts "Lich folders found on this PC: #{found.empty? ? 'none' : ''}"
  found.each { |d| puts "  #{ChronoConfig.disp(d)}" }
  true
end

def cmd_set_lich_dir(dir)
  fail! "Use: chrono set-lich-dir \"#{ChronoConfig.example_lich_dir}\"" unless dir
  fail! ChronoConfig.why_invalid(dir) unless ChronoConfig.valid_lich_dir?(dir)
  ChronoConfig.save('lich_dir' => ChronoConfig.normalize(dir))
  puts "Lich folder set to #{ChronoConfig.disp(ChronoConfig.normalize(dir))}"
  true
end

# chrono set-dr-lich-dir FOLDER   (or "same", for the same Lich folder as GemStone)
def cmd_set_dr_lich_dir(dir)
  fail! "Use: chrono set-dr-lich-dir \"#{ChronoConfig.example_lich_dir}\"   (or: same)" unless dir
  if dir.casecmp?('same') || ChronoConfig.normalize(dir) == LICH_DIR
    ChronoConfig.save('dr_lich_dir' => nil)
    puts 'DragonRealms characters now use the same Lich folder as GemStone.'
  else
    fail! ChronoConfig.why_invalid(dir) unless ChronoConfig.valid_lich_dir?(dir)
    ChronoConfig.save('dr_lich_dir' => ChronoConfig.normalize(dir))
    puts "DragonRealms Lich folder set to #{ChronoConfig.disp(ChronoConfig.normalize(dir))}"
  end
  true
end

# Used by the installer after an upgrade, so tasks point at the current Ruby and files.
def cmd_rebuild_tasks
  return (puts('No Lich folder set yet, so there are no schedules to rebuild.') || true) unless LICH_DIR
  list = Schedules.load
  list.each { |s| Schedules.install!(s) }
  rewards = Rewards.load
  Rewards.install_task!(rewards) if rewards['enabled']
  log "Rebuilt the scheduled tasks for #{list.size} schedule(s)#{rewards['enabled'] ? ' and daily rewards' : ''}."
  true
end

# Used by the uninstaller. Schedules stay saved in the Lich data folder, so a reinstall
# followed by "Rebuild scheduled tasks" brings them back.
def cmd_remove_tasks
  return (puts('No Lich folder set, so there are no schedules to remove.') || true) unless LICH_DIR
  list = Schedules.load
  list.each { |s| Schedules.uninstall!(s) }
  Rewards.uninstall_task!
  log "Removed the scheduled tasks for #{list.size} schedule(s) and daily rewards."
  true
end

# Uninstalling, when the player also wants Chrono's data gone: Lich5/data/chrono (schedules,
# rewards settings and history, the log, and Chrono's backups of Lich's saved logins) and the
# in-game helper script. Lich's saved logins themselves are Lich's, and aren't touched.
def cmd_remove_data
  return (puts('No Lich folder set, so there is no Chrono data to remove.') || true) unless LICH_DIR
  FileUtils.rm_rf(STATE_DIR)
  helper = File.join(SCRIPT_DIR, "#{HELPER}.lic")
  File.delete(helper) if File.exist?(helper)
  puts "Deleted #{ChronoConfig.disp(STATE_DIR)} and the in-game helper."
  true
end

# ---------- rewards commands ----------

def cmd_run_rewards(accounts)
  log "REWARDS run starting#{accounts.empty? ? '' : " for #{accounts.join(', ')}"}"
  ok = Rewards.run(accounts)
  log(ok ? 'REWARDS run finished.' : '!!! REWARDS run finished with problems (details above).', ok ? $stdout : $stderr)
  ok
end

def cmd_rewards
  data = Rewards.load
  puts "Daily rewards: #{data['enabled'] ? "on, every day at #{data['time']}" : "off (would run at #{data['time']})"}"
  list = Rewards.accounts(data)
  puts 'No saved accounts yet.' if list.empty?
  list.each do |a|
    puts format('  %-16s %-9s SimuCoins %-4s Daily logins %-4s Claim on %-7s %s', a[:name], a[:plan] || '?',
                a[:coins] ? 'on' : 'off', a[:daily] ? 'on' : 'off', a[:where] == 'github' ? 'GitHub' : 'this PC',
                a[:where] == 'github' ? '' : Rewards.summary(a[:last]))
  end
  gh = Rewards.github_state(data)
  if gh && !gh['stopped']
    puts "GitHub: github.com/#{gh['repo']} (#{Array(gh['accounts']).join(', ')}), set up #{Time.at(gh['at']).strftime('%b %-d %-I:%M %p')}. " \
         "Results: #{ChronoGitHub.actions_url(gh['repo'])}"
  end
  if (ex = Rewards.exact_state(data))
    puts "Exact timing: cron-job.org starts the GitHub run at #{ex['time']} (#{ex['tz']}); GitHub's own schedule is a backup " \
         "at #{ChronoGitHub.backup_time(ex['time'])}."
  end
  why = Rewards.github_needs_update(data)
  puts "GitHub needs updating: #{why}. Run: chrono github-setup" if why
  why = Rewards.exact_needs_update(data)
  puts "Exact timing needs updating: #{why}. Run: chrono exact-setup" if why
  true
end

def ask_line(prompt)
  fail! 'This command needs a terminal to type into.' unless $stdin.tty?
  $stdout.print prompt
  $stdin.gets.to_s.strip
end

# chrono exact-setup: sets up (or, after the time changed, updates) cron-job.org starting the
# GitHub run at the exact time. Asks for the GitHub token and the cron-job.org API key.
def cmd_exact_setup
  gh = Rewards.github_state
  fail! 'Set up GitHub first: chrono github-setup' unless gh && gh['repo'] && !gh['stopped']
  if Rewards.exact_state && Rewards.exact_needs_update && !Rewards.exact_token_expiring?
    key = ask_password('cron-job.org API key (cron-job.org > Settings > API): ')
    Rewards.exact_update_time!(key)
    puts "cron-job.org now starts the run at #{Rewards.load['time']}."
  else
    puts 'Exact timing: cron-job.org (free) starts your GitHub rewards run at the exact time each day.'
    puts
    puts '1. Create a GitHub token for it. Open this page (already filled in):'
    puts "   #{ChronoGitHub.run_token_url}"
    puts "   Under Repository access choose \"Only select repositories\" and pick #{ChronoGitHub::REPO_NAME}."
    puts '   Click "Generate token" and copy it.'
    token = ask_password('   Paste the token: ')
    puts '2. Make a free account at https://cron-job.org, then Settings > API > create an API key.'
    key = ask_password('   Paste the API key: ')
    Rewards.exact_setup!(key, token, progress: ->(line) { puts "  #{line}" })
  end
  if Rewards.github_needs_update
    puts 'Now updating GitHub, so its own schedule becomes the backup:'
    Rewards.github_sync!(github_sign_in_cli, progress: ->(line) { puts "  #{line}" })
  end
  puts 'Done.'
  true
end

def cmd_exact_stop
  fail! 'Exact timing isn\'t set up.' unless Rewards.exact_state
  key = ask_password('cron-job.org API key, to delete the job (leave empty to delete it on cron-job.org yourself): ')
  Rewards.exact_stop!(key.empty? ? nil : key)
  puts key.empty? ? 'Exact timing off. Delete the "Chrono4Lich rewards" job on cron-job.org.' : 'Exact timing off.'
  puts 'Also delete the "Chrono4Lich exact timing" token on GitHub (Settings > Developer settings > Personal access tokens).'
  if Rewards.github_needs_update
    puts 'Now updating GitHub, so its own schedule runs at the claim time again:'
    Rewards.github_sync!(github_sign_in_cli, progress: ->(line) { puts "  #{line}" })
  end
  true
end

# Prints the code to enter on GitHub and waits for approval. Returns the token (not saved).
def github_sign_in_cli
  device = ChronoGitHub.start_sign_in
  puts
  puts "  1. Open #{device[:verification_uri]}"
  puts "  2. Enter the code:  #{device[:user_code]}"
  puts '  3. Approve Chrono4Lich.'
  puts
  puts 'Waiting for you to approve on GitHub...'
  ChronoGitHub.wait_for_token(device)
end

def cmd_github_setup
  wanted = Rewards.github_accounts
  fail! 'No accounts are set to claim on GitHub. Use: chrono rewards-set ACCOUNT where github' if wanted.empty?
  puts "This stores the Simutronics logins for #{wanted.map { |a| a[:name] }.join(', ')} as encrypted secrets"
  puts 'in a private repository on your GitHub account, and claims rewards there every day.'
  puts ChronoGitHub::ACTION_NOTICE
  token = github_sign_in_cli
  Rewards.github_sync!(token, progress: ->(line) { puts "  #{line}" })
  gh = Rewards.github_state
  puts "Done. Watch the first run at #{ChronoGitHub.actions_url(gh['repo'])}"
  puts "Chrono doesn't keep the GitHub sign-in. To withdraw its access: #{ChronoGitHub::REVOKE_URL}"
  true
end

def cmd_github_stop
  gh = Rewards.github_state
  fail! 'GitHub was never set up from this computer.' unless gh && gh['repo']
  puts "This turns off the schedule in github.com/#{gh['repo']} and deletes the stored logins there."
  token = github_sign_in_cli
  Rewards.github_stop!(token)
  puts "Done. The repository itself is still on GitHub; delete it there if you like (Settings, at the bottom)."
  if Rewards.exact_state
    key = ask_password('Exact timing was on. cron-job.org API key, to delete its job (leave empty to delete it yourself): ')
    Rewards.exact_stop!(key.empty? ? nil : key)
    puts 'Delete the "Chrono4Lich rewards" job on cron-job.org.' if key.empty?
    puts 'Also delete the "Chrono4Lich exact timing" token on GitHub (Settings > Developer settings > Personal access tokens).'
  end
  true
end

# chrono rewards-set on|off [HH:MM]   or   chrono rewards-set ACCOUNT coins|daily on|off
def cmd_rewards_set(args)
  usage = 'Use: chrono rewards-set on [HH:MM] | off | ACCOUNT coins on|off | ACCOUNT daily on|off | ACCOUNT where pc|github'
  case args.map(&:downcase)
  in ['on'] | ['on', _]
    d = Rewards.set_schedule(true, args[1])
    puts "Daily rewards on, every day at #{d['time']}."
  in ['off']
    Rewards.set_schedule(false)
    puts 'Daily rewards off.'
  in [_, 'where', ('pc' | 'github') => where]
    unless Rewards.accounts.any? { |a| a[:name].casecmp?(args[0]) }
      fail! "No saved login for account #{args[0]}."
    end
    Rewards.set_account(args[0], where: where)
    puts "#{args[0].upcase}: claims on #{where == 'github' ? 'GitHub' : 'this PC'}."
    puts 'Run "chrono github-setup" to update GitHub.' if Rewards.github_needs_update
  in [_, ('coins' | 'daily') => what, ('on' | 'off') => value]
    acct = args[0]
    unless Rewards.accounts.any? { |a| a[:name].casecmp?(acct) }
      fail! "No saved login for account #{acct}."
    end
    Rewards.set_account(acct, what.to_sym => value == 'on')
    puts "#{acct.upcase}: #{what == 'coins' ? 'SimuCoins' : 'daily login rewards'} #{value}."
  else
    fail! usage
  end
  true
end

QUICK_STAY = (ChronoConfig.dev_env('CHRONO_QUICK_STAY') || 45).to_i # seconds a quick (no logout time) scheduled login stays in once the game confirms it (override: testing only)

# launchd (Mac) runs a missed timed job as soon as the Mac wakes. Right for rewards, wrong for
# a login: so a scheduled login or logout more than LATE_LIMIT minutes after its time is skipped.
LATE_LIMIT = 10

def too_late?(scheduled_for)
  return false unless scheduled_for.to_s.match?(/\A\d{1,2}:\d{2}\z/)

  h, m = scheduled_for.split(':').map(&:to_i)
  now = Time.now
  ((now.hour * 60 + now.min) - (h * 60 + m)) % 1440 > LATE_LIMIT
end

def cmd_run_schedule(kind, name, scheduled_for: nil)
  fail! 'Use: run-schedule login|logout "Schedule name"' unless %w[login logout].include?(kind) && name
  if too_late?(scheduled_for)
    log "SCHEDULE #{name}: the #{kind} was due at #{scheduled_for} (the computer was probably asleep); skipped"
    return true
  end
  s = Schedules.find(name)
  log "SCHEDULE #{s['name']}: scheduled #{kind} starting"
  if kind == 'login'
    if !Gem.win_platform? && !ChronoConfig.mac? && ENV['DISPLAY'].to_s.empty? && ENV['WAYLAND_DISPLAY'].to_s.empty?
      fail! 'The scheduled login has no desktop to open the game on (DISPLAY and WAYLAND_DISPLAY are not set). ' \
            'Make sure you are logged in to your desktop, then open Chrono and click ' \
            '"Rebuild scheduled tasks" on the Settings tab.'
    end
    scripts = s['scripts'].to_s.split(',').map(&:strip).reject(&:empty?)
    # characters already online (someone is playing them) are skipped, and never logged out here
    already = s['characters'].select { |spec| online?(who_from_spec(spec)) }
    ok = cmd_login(s["characters"], nil, scripts, 120, 2, skip_online: true)
    return ok if s['logout_at'] # logs out at its set time

    # No logout time: a quick login, as a safety limit. Once the game confirms they're in, stay
    # QUICK_STAY seconds (long enough to count as a login, e.g. for the daily reward), then log out.
    ours = (s['characters'] - already).select { |spec| online?(who_from_spec(spec)) }
    return ok if ours.empty?

    log "SCHEDULE #{s['name']}: no logout time, so logging out #{ours.join(', ')} in #{QUICK_STAY}s (quick login)"
    sleep QUICK_STAY
    cmd_logout(ours, 90, skip_offline: true) && ok
  else
    cmd_logout(s['characters'], 90, skip_offline: true)
  end
end

require_relative 'chrono_schedule'
require_relative 'chrono_rewards'
require_relative 'chrono_github'
require_relative 'chrono_cronjob'
require_relative 'chrono_update'

# ---------- carrying over from lichsched (Chrono's old name) ----------

LEGACY_STATE_DIR = LICH_DIR && File.join(DATA_DIR, 'lichsched')
LEGACY_DONE_MARKER = 'MOVED_TO_CHRONO.txt'

# Copies lichsched's data (schedules, log) into Chrono's data folder, swaps the old scheduled
# tasks/timers for Chrono's, and removes the old helper. Runs once; does nothing afterwards.
# Files are copied rather than the folder renamed, because Windows refuses to rename a folder
# that anything has open (an Explorer window, antivirus, the old lichsched window).
# Returns the names of characters still online under the old helper. While any are, nothing
# is moved, because their sessions still write to the old folder.
def migrate_from_lichsched!
  return [] unless LICH_DIR && File.directory?(LEGACY_STATE_DIR)
  return [] if File.exist?(File.join(LEGACY_STATE_DIR, LEGACY_DONE_MARKER))
  # Nothing worth carrying over (e.g. an empty folder Windows wouldn't let us delete): tidy up.
  if Dir.glob(File.join(LEGACY_STATE_DIR, '{schedules.json,lichsched.log,*.status.json}')).empty?
    FileUtils.rm_rf(LEGACY_STATE_DIR)
    return []
  end
  still_online = Dir.glob(File.join(LEGACY_STATE_DIR, '*.status.json')).filter_map do |f|
    st = (JSON.parse(File.read(f)) rescue nil)
    st && st['state'] != 'offline' && lich_alive?(st) ? st['name'] : nil
  end
  unless still_online.empty?
    log "Not carrying over lichsched's data yet: #{still_online.join(', ')} still online under lichsched. " \
        'Quit them in the game (QUIT), then open Chrono again.'
    return still_online
  end

  ensure_state_dir
  # Schedules: take lichsched's unless Chrono already has its own.
  old_sched = File.join(LEGACY_STATE_DIR, 'schedules.json')
  new_sched = File.join(STATE_DIR, 'schedules.json')
  FileUtils.cp(old_sched, new_sched) if File.exist?(old_sched) && !File.exist?(new_sched)
  # Log: lichsched's history first, then anything Chrono has logged so far.
  old_log = File.join(LEGACY_STATE_DIR, 'lichsched.log')
  new_log = File.join(STATE_DIR, 'chrono.log')
  if File.exist?(old_log)
    merged = File.read(old_log) + (File.exist?(new_log) ? File.read(new_log) : '')
    File.write("#{new_log}.tmp", merged)
    File.rename("#{new_log}.tmp", new_log)
  end
  # (status files from the old helper are useless to Chrono, so they aren't copied)

  # Mark the old folder as done first, so this never runs twice even if it can't be deleted.
  File.write(File.join(LEGACY_STATE_DIR, LEGACY_DONE_MARKER),
             "lichsched's data was copied to #{ChronoConfig.disp(STATE_DIR)} on #{Time.now}.\n" \
             "This folder can be deleted.\n")
  FileUtils.rm_rf(LEGACY_STATE_DIR) # quietly leaves it if Windows still has it open
  if File.directory?(LEGACY_STATE_DIR)
    log "Couldn't delete the old folder #{ChronoConfig.disp(LEGACY_STATE_DIR)} (something has it open). " \
        'Everything is copied, so you can delete it yourself later.'
  end

  list = Schedules.load
  list.each do |s|
    Schedules.remove_legacy!(s)
    Schedules.install!(s)
  end
  old_helper = File.join(SCRIPT_DIR, 'lichsched_helper.lic')
  File.delete(old_helper) if File.exist?(old_helper)
  log "Carried over from lichsched: data moved to #{ChronoConfig.disp(STATE_DIR)}, " \
      "#{list.size} schedule(s) moved to #{Schedules.scheduler_name}."
  []
rescue SystemCallError => e
  fail! "Couldn't bring lichsched's data over from #{ChronoConfig.disp(LEGACY_STATE_DIR)}: #{e.message}. " \
        'Close any window showing that folder, and the old lichsched window if it\'s still open, ' \
        'then open Chrono again. Nothing has been lost.'
end

# The GUI loads this file for its helpers; only run the command line when started directly.
return unless __FILE__ == $PROGRAM_NAME

$stdout.sync = true
$stderr.sync = true

opts = { realm: nil, scripts: [], timeout: nil, gap: 2 }
parser = OptionParser.new do |o|
  o.banner = 'Usage: chrono <list|status|login|logout|kill|add-login|change-password|remove-login|rewards|rewards-set|run-rewards|github-setup|github-stop|exact-setup|exact-stop|config|set-lich-dir|set-dr-lich-dir> [Name ...|all] [options]'
  o.on('--realm REALM', 'Realm for names saved in more than one realm') { |v| opts[:realm] = v.downcase }
  o.on('--scripts LIST', 'Comma-separated scripts to start after login') do |v|
    opts[:scripts] = v.split(',').map(&:strip).reject(&:empty?)
  end
  o.on('--timeout SECONDS', Integer, 'How long to wait per character (login 120, logout 90)') { |v| opts[:timeout] = v }
  o.on('--gap SECONDS', Integer, 'Seconds between starting each login (default 2); they log in at the same time') { |v| opts[:gap] = v }
  o.on('--notify', 'Show a pop-up if anything fails (used by scheduled tasks)') { opts[:notify] = true }
  o.on('--scheduled-for HH:MM', 'run-schedule: skip if run more than 10 minutes after this time (Mac)') { |v| opts[:scheduled_for] = v }
  o.on('--frontend NAME', 'Frontend for add-login (default: the one your saved logins use most)') { |v| opts[:frontend] = v.downcase }
end

# A plain title for the pop-up, e.g. "Claiming rewards" or "The scheduled login for 'Morning'".
friendly_task = lambda do
  case ARGV.first
  when 'run-rewards' then 'Claiming rewards'
  when 'run-schedule' then "The scheduled #{ARGV[1]} for '#{ARGV[2]}'"
  else "chrono #{ARGV.reject { |a| a == '--notify' }.first(3).join(' ')}"
  end
end

notify_failure = lambda do |what|
  next unless opts[:notify]
  details = ERRORS_SEEN.uniq.reject { |e| e.start_with?('LOGIN SUMMARY', 'LOGOUT SUMMARY', 'REWARDS run finished') }
                       .map { |e| e.sub(/\AREWARDS /, '') }.first(10).join("\n\n")
  notify_box('Chrono', "#{what} had problems:\n\n#{details}\n\nDetails are in chrono.log.")
end

begin
  # Started by Task Scheduler under rubyw there is no console; printing would fail.
  if Gem.win_platform? && defined?(Fiddle)
    get_std = Fiddle::Function.new(Fiddle.dlopen('kernel32')['GetStdHandle'], [Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP)
    { -11 => $stdout, -12 => $stderr }.each do |id, io|
      handle = get_std.call(id).to_i
      io.reopen(File::NULL, 'w') if [0, -1, 2**64 - 1, 2**32 - 1].include?(handle)
    end
  end

  command, *names = parser.parse(ARGV)
  needs_name = %w[login logout kill run-schedule].include?(command)
  if command.nil? || (needs_name && names.empty?)
    puts parser
    exit 2
  end
  require_lich_dir! unless %w[config set-lich-dir rebuild-tasks remove-tasks remove-data].include?(command)
  waiting = LICH_DIR && !%w[config set-lich-dir remove-tasks remove-data].include?(command) ? migrate_from_lichsched! : []
  ok =
    case command
    when 'config'        then cmd_config
    when 'rebuild-tasks' then cmd_rebuild_tasks
    when 'remove-tasks'  then cmd_remove_tasks
    when 'remove-data'   then cmd_remove_data
    when 'set-lich-dir' then cmd_set_lich_dir(names.first)
    when 'set-dr-lich-dir' then cmd_set_dr_lich_dir(names.first)
    when 'run-rewards'     then cmd_run_rewards(names)
    when 'github-setup'    then cmd_github_setup
    when 'github-stop'     then cmd_github_stop
    when 'exact-setup'     then cmd_exact_setup
    when 'exact-stop'      then cmd_exact_stop
    when 'rewards'         then cmd_rewards
    when 'rewards-set'     then cmd_rewards_set(names)
    when 'add-login'       then cmd_add_login(names.first, opts[:frontend])
    when 'change-password' then cmd_change_password(names.first)
    when 'remove-login'    then cmd_remove_login(names.first)
    when 'list'   then cmd_list || true
    when 'version', '--version' then puts("Chrono #{CHRONO_VERSION}") || true
    when 'check-update'
      rel = ChronoGitHub.latest_release
      if rel.nil? then puts "Couldn't check for updates right now."
      elsif ChronoGitHub.newer?(rel[:version], CHRONO_VERSION) then puts "Chrono #{rel[:version]} is available (you have #{CHRONO_VERSION}): #{rel[:url]}"
      else puts "Chrono #{CHRONO_VERSION} is the latest version."
      end
      true
    when 'status' then cmd_status || true
    when 'login'  then cmd_login(names, opts[:realm], opts[:scripts], opts[:timeout] || 120, opts[:gap])
    when 'logout' then cmd_logout(names, opts[:timeout] || 90)
    when 'kill'
      fail! 'kill takes exactly one name.' unless names.size == 1
      cmd_kill(names.first)
    when 'run-schedule'
      cmd_run_schedule(names[0], names[1], scheduled_for: opts[:scheduled_for])
    else
      puts parser
      exit 2
    end
  notify_failure.call(friendly_task.call) unless ok
  # tells the installers that lichsched's schedules are waiting on characters still online
  exit 3 if ok && command == 'rebuild-tasks' && !waiting.empty?
  exit(ok ? 0 : 1)
rescue Errno::EPIPE
  exit 0 # output was cut short (e.g. piped into head); nothing went wrong
rescue Fail, ChronoEAccess::Error, ChronoGitHub::Error, ChronoCronJob::Error, ChronoUpdate::Error, OptionParser::ParseError => e
  log "!!! ERROR: #{e.message}", $stderr
  notify_failure.call(friendly_task.call)
  exit 1
rescue => e
  log "!!! UNEXPECTED ERROR: #{e.class}: #{e.message}", $stderr
  begin
    e.backtrace.first(5).each { |l| $stderr.puts "    #{l}" }
  rescue IOError, SystemCallError
    nil
  end
  notify_failure.call(friendly_task.call)
  exit 1
end
