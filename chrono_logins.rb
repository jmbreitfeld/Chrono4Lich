# chrono_logins.rb - reads and changes Lich's saved logins.
# Loaded by chrono.rb; needs its helpers (fail!, log, LICH_DIR, lich_dir_for, lich_folders, rubyw_path).
#
# Lich keeps saved logins in one of two files:
#   entry.yaml  newer Lich (5.13+). Passwords may be encrypted, possibly with a master password
#               in the system keychain, so Chrono changes it only through Lich's own commands
#               (lich.rbw --add-account / --add-character / --change-account-password), except
#               removing a character, which doesn't touch passwords.
#   entry.dat   older Lich. Chrono writes it directly, in the same format elogin does.
# When both exist, Lich uses entry.yaml, so Chrono does too.
# Every change is preceded by a backup in data/chrono/backups.

require 'yaml'
require 'open3'
require 'securerandom'
require 'fileutils'

module SavedLogins
  GAME_NAMES = { 'GS3' => 'GemStone IV', 'GSX' => 'GemStone IV Platinum',
                 'GSF' => 'GemStone IV Shattered', 'GST' => 'GemStone IV Test',
                 'DR' => 'DragonRealms', 'DRX' => 'DragonRealms Platinum',
                 'DRF' => 'DragonRealms The Fallen', 'DRT' => 'DragonRealms Test' }.freeze
  KEEP_BACKUPS = 10
  # Warlock isn't one of Lich's frontends: Lich runs it as a "custom launch" command saved with
  # the login (frontend stormfront, since Warlock speaks Stormfront's protocol). Chrono shows such
  # logins as "warlock" and offers it as a frontend choice.
  WARLOCK = 'warlock'
  WARLOCK_BASE_FRONTEND = 'stormfront'

  module_function

  # ---------- which Lich folder ----------
  # GemStone and DragonRealms logins can be saved in different Lich folders (see lich_dir_for).
  # Everything below reads and changes the folder in use: GemStone's, unless inside in_folder.
  # (Per thread, since the window changes saved logins in the background.)

  def lich_dir = Thread.current[:chrono_lich_dir] || LICH_DIR
  def data_dir = File.join(lich_dir, 'data')

  def in_folder(dir)
    old = Thread.current[:chrono_lich_dir]
    Thread.current[:chrono_lich_dir] = dir
    yield
  ensure
    Thread.current[:chrono_lich_dir] = old
  end

  # The Lich folder a game's logins are saved in.
  def folder_for(game_code)
    lich_dir_for(game_code) or fail! "Chrono can't find the DragonRealms Lich folder: #{DR_LICH_DIR_PROBLEM}"
  end

  # Lich folders where this account is saved.
  def folders_with(account)
    lich_folders.select { |dir| in_folder(dir) { saved_here?(account) } }
  end

  def saved_here?(account)
    case backend
    when :yaml then File.exist?(yaml_file) && (load_yaml['accounts'] || {}).keys.any? { |k| k.to_s.casecmp?(account) }
    else File.exist?(dat_file) && dat_entries.any? { |e| e[:user_id].to_s.casecmp?(account) }
    end
  end

  # Any saved logins at all, in any Lich folder Chrono uses.
  def any_saved?
    lich_folders.any? { |dir| in_folder(dir) { File.exist?(yaml_file) || File.exist?(dat_file) } }
  end

  def yaml_file = File.join(data_dir, 'entry.yaml')
  def dat_file  = File.join(data_dir, 'entry.dat')

  # :yaml or :dat - which file Lich reads (or, with neither, which one a new login goes into).
  def backend
    return :yaml if File.exist?(yaml_file)
    return :dat if File.exist?(dat_file)
    lich_has_cli? ? :yaml : :dat
  end

  def lich_has_cli?
    File.exist?(File.join(lich_dir, 'lib', 'common', 'cli', 'cli_orchestration.rb'))
  end

  def lich_version
    src = File.read(File.join(lich_dir, 'lib', 'version.rb')) rescue nil
    src && src[/LICH_VERSION\s*=\s*['"]([^'"]+)/, 1]
  end

  # Frontends this Lich accepts for new logins (read from Lich itself when it says), plus Warlock.
  def frontends
    helpers = File.join(lich_dir, 'lib', 'common', 'authentication', 'login_helpers.rb')
    list = (File.read(helpers)[/VALID_FRONTENDS\s*=\s*%w\[([^\]]*)\]/, 1] rescue nil)&.split
    list = %w[stormfront wizard avalon] if list.nil? || list.empty?
    # the ones already in use come first, most used first
    used = entries.map { |e| e[:frontend].to_s }.reject(&:empty?).tally.sort_by { |_, n| -n }.map(&:first)
    (used + list + [WARLOCK]).uniq
  end

  def warlock_launch?(custom_launch) = custom_launch.to_s.downcase.include?(WARLOCK)

  # "Open Warlock full screen": Warlock sets its own window size (the last one it saved, or the
  # one saved for the character), so Windows' "start maximized" has no effect on it. Warlock does
  # take --width/--height/-x/-y, and a size given that way wins over its saved ones, so Chrono adds
  # the screen's size (its usable area, in Warlock's "display pixels") at the top-left corner.
  OLD_MAXIMIZED_PREFIX = 'cmd /c start "" /max ' # what Chrono 1.8.1 added; removed when seen
  SIZE_ARGS_RE = /\s+--width\s+\d+\s+--height\s+\d+\s+-x\s+-?\d+\s+-y\s+-?\d+/

  def maximize_supported? = true

  def maximized?(cmd) = cmd.to_s.match?(SIZE_ARGS_RE)

  # [width, height] the command asks for, or nil
  def full_screen_size(cmd)
    m = cmd.to_s.match(/--width\s+(\d+)\s+--height\s+(\d+)/)
    m && [m[1].to_i, m[2].to_i]
  end

  # The command without any size Chrono added, then (on) with the screen's size, or the given one.
  def with_maximized(cmd, on, size: nil)
    base = cmd.to_s.strip
    base = base[OLD_MAXIMIZED_PREFIX.length..].to_s.strip while base.downcase.start_with?(OLD_MAXIMIZED_PREFIX.downcase)
    base = base.gsub(SIZE_ARGS_RE, '').strip
    return base unless on

    x, y, w, h = screen_area
    w, h = size if size
    "#{base} --width #{w} --height #{h} -x #{x} -y #{y}"
  end

  # The main screen's usable area (without the taskbar) as [x, y, width, height] in the units
  # Warlock's options use (pixels at 100% display scaling).
  def screen_area
    @screen_area ||= detect_screen_area || [0, 0, 1920, 1040]
  end

  def detect_screen_area
    if Gem.win_platform?
      require 'fiddle'
      user32 = Fiddle.dlopen('user32')
      spi = Fiddle::Function.new(user32['SystemParametersInfoW'],
                                 [Fiddle::TYPE_UINT, Fiddle::TYPE_UINT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_UINT], Fiddle::TYPE_INT)
      rect = Fiddle::Pointer.malloc(16, Fiddle::RUBY_FREE)
      return nil if spi.call(0x30, 0, rect, 0).zero? # SPI_GETWORKAREA

      l, t, r, b = rect[0, 16].unpack('l4')
      dpi = (Fiddle::Function.new(user32['GetDpiForSystem'], [], Fiddle::TYPE_UINT).call rescue 96)
      scale = dpi.to_i.positive? ? dpi / 96.0 : 1.0
      [l, t, r - l, b - t].map { |v| (v / scale).round }
    elsif defined?(Gdk::Display)
      mon = Gdk::Display.default&.primary_monitor || Gdk::Display.default&.get_monitor(0)
      wa = mon&.workarea
      wa && [wa.x, wa.y, wa.width, wa.height]
    end
  rescue StandardError, LoadError
    nil
  end

  # Turns "Open Warlock full screen" on or off for every saved Warlock login. Returns how many changed.
  def set_warlock_maximized_all(on)
    lich_folders.sum { |dir| in_folder(dir) { set_warlock_maximized_here(on) } }
  end

  def set_warlock_maximized_here(on)
    n = 0
    return 0 unless File.exist?(yaml_file) || File.exist?(dat_file)

    if backend == :yaml
      edit_yaml do |data|
        (data['accounts'] || {}).each_value do |acct|
          Array(acct['characters']).each do |c|
            next unless mine?(c['game_code']) && warlock_launch?(c['custom_launch'])
            next if on && maximized?(c['custom_launch']) # keep a size already chosen

            new_cmd = with_maximized(c['custom_launch'], on)
            next if new_cmd == c['custom_launch']

            c['custom_launch'] = new_cmd
            n += 1
          end
        end
      end
    else
      list = dat_entries
      list.each do |e|
        next unless mine?(e[:game_code]) && warlock_launch?(e[:custom_launch])
        next if on && maximized?(e[:custom_launch]) # keep a size already chosen

        new_cmd = with_maximized(e[:custom_launch], on)
        next if new_cmd == e[:custom_launch]

        e[:custom_launch] = new_cmd
        n += 1
      end
      write_dat(list) if n.positive?
    end
    log "LOGINS Warlock maximized #{on ? 'on' : 'off'} for #{n} saved login(s)"
    n
  end

  # What Chrono shows as a login's frontend: "warlock" for a Warlock custom launch.
  def shown_frontend(frontend, custom_launch)
    warlock_launch?(custom_launch) ? WARLOCK : frontend.to_s
  end

  # ---------- Warlock moved by an update ----------
  # Saved Warlock logins hold the full path of Warlock's program. An update can move it: Warlock
  # 3.1 installs for the user (AppData\Local\Programs\Warlock) where 3.0 used Program Files.
  # Lich then can't start Warlock and the login fails. Before logging in, Chrono notices that,
  # finds where Warlock is now, and updates the saved logins that pointed at the old place.

  # The program a launch command runs: its first word, which may be in "quotes".
  def launch_program(cmd)
    cmd = cmd.to_s.strip
    cmd.start_with?('"') ? cmd[1..].to_s[/\A[^"]*/].to_s : cmd.split(/\s+/, 2).first.to_s
  end

  # Where Warlock's program is on this computer, or nil.
  def find_warlock
    list =
      if Gem.win_platform?
        local = ENV['LOCALAPPDATA'].to_s.tr('\\', '/')
        [*([File.join(local, 'Programs', 'Warlock', 'Warlock.exe')] unless local.empty?),
         *%w[ProgramFiles ProgramW6432 ProgramFiles(x86)].filter_map { |v| ENV[v] && File.join(ENV[v].tr('\\', '/'), 'Warlock', 'Warlock.exe') },
         *(local.empty? ? [] : Dir.glob(File.join(local, 'Programs', 'Warlock*', 'Warlock*.exe')))]
      elsif RUBY_PLATFORM.include?('darwin')
        ['/Applications/Warlock.app/Contents/MacOS/Warlock', File.join(Dir.home, 'Applications/Warlock.app/Contents/MacOS/Warlock')]
      else
        ['/usr/bin/warlock', '/usr/local/bin/warlock', '/opt/warlock/bin/Warlock', File.join(Dir.home, '.local/bin/warlock')]
      end
    found = list.find { |f| File.file?(f) }
    found && Gem.win_platform? ? found.tr('/', '\\') : found
  end

  def absolute_path?(path) = path.match?(%r{\A([a-z]:)?[\\/]}i)

  # A saved Warlock launch that can no longer start Warlock: its program (a full path) is gone,
  # or (Windows) it names the program alone and Lich's folder for it no longer holds it. (Lich
  # changes to that folder first, then starts the program from there.)
  def warlock_broken?(cmd, dir)
    prog = launch_program(cmd)
    return !File.exist?(prog) if absolute_path?(prog)
    return false if dir.to_s.empty? || !Gem.win_platform? # found on the PATH

    exe = prog.downcase.end_with?('.exe') ? prog : "#{prog}.exe"
    !File.exist?(File.join(dir.to_s.tr('\\', '/'), exe))
  end

  # The launch command and folder, pointed at Warlock's program at now.
  def warlock_fixed(cmd, dir, now)
    now_dir = File.dirname(now.tr('\\', '/'))
    now_dir = now_dir.tr('/', '\\') if Gem.win_platform?
    prog = launch_program(cmd)
    rest = cmd.to_s.strip
    rest = rest.start_with?('"') ? rest.sub(/\A"[^"]*"/, '') : rest.sub(/\A\S+/, '')
    if absolute_path?(prog)
      new_prog = now.include?(' ') ? %("#{now}") : now
      [new_prog + rest, dir.to_s.empty? ? dir : now_dir]
    elsif File.basename(now, '.*').casecmp?(File.basename(prog, '.*'))
      [cmd, now_dir] # same program name: only its folder moved
    else
      [(now.include?(' ') ? %("#{now}") : now) + rest, now_dir]
    end
  end

  # Checks the Warlock logins in entries; if any can no longer start Warlock (an update moved
  # it), points every such saved login at where Warlock is now. Fails, saying what to do, if
  # Warlock can't be found. Call it once, before starting any logins.
  def fix_moved_warlock!(entries)
    broken = entries.select { |e| e[:frontend] == WARLOCK && warlock_broken?(e[:custom_launch], e[:custom_launch_dir]) }
    return if broken.empty?

    e = broken.first
    was = absolute_path?(launch_program(e[:custom_launch])) ? launch_program(e[:custom_launch]) : e[:custom_launch_dir]
    now = find_warlock or
      fail! "Warlock isn't at #{was} any more (an update may have moved it), and Chrono couldn't find " \
            "where it is now. On the Logins tab, Edit #{e[:char_name]}'s login and put Warlock's new location in its command."
    n = lich_folders.sum { |dir| in_folder(dir) { repoint_warlock_here(now) } }
    log "LOGINS Warlock moved (was #{was}, now #{now}): updated #{n} saved login(s)"
  end

  def repoint_warlock_here(now)
    return 0 unless File.exist?(yaml_file) || File.exist?(dat_file)

    needs = ->(cmd, dir) { warlock_launch?(cmd) && warlock_broken?(cmd, dir) }
    n = 0
    if backend == :yaml
      chars = (load_yaml['accounts'] || {}).values.flat_map { |a| Array(a['characters']) }
      return 0 unless chars.any? { |c| mine?(c['game_code']) && needs.call(c['custom_launch'], c['custom_launch_dir']) }

      edit_yaml do |d|
        (d['accounts'] || {}).each_value do |acct|
          Array(acct['characters']).each do |c|
            next unless mine?(c['game_code']) && needs.call(c['custom_launch'], c['custom_launch_dir'])

            c['custom_launch'], c['custom_launch_dir'] = warlock_fixed(c['custom_launch'], c['custom_launch_dir'], now)
            n += 1
          end
        end
      end
    else
      list = dat_entries
      list.each do |e|
        next unless mine?(e[:game_code]) && needs.call(e[:custom_launch], e[:custom_launch_dir])

        e[:custom_launch], e[:custom_launch_dir] = warlock_fixed(e[:custom_launch], e[:custom_launch_dir], now)
        n += 1
      end
      write_dat(list) if n.positive?
    end
    n
  end

  # The command Lich runs to start Warlock, and the folder to run it in: copied from a login that
  # already uses Warlock (so it matches what works on this computer), otherwise Lich's own
  # preset for this system. [command, folder or nil]
  def warlock_launch
    used = entries.select { |e| e[:frontend] == WARLOCK }
                  .map { |e| [e[:custom_launch].to_s, e[:custom_launch_dir].to_s.empty? ? nil : e[:custom_launch_dir].to_s] }
    return used.tally.max_by { |_, n| n }.first unless used.empty?
    found = find_warlock
    return [%(#{found.include?(' ') ? %("#{found}") : found} --host localhost --port %port% --key %key%),
            Gem.win_platform? ? File.dirname(found.tr('\\', '/')).tr('/', '\\') : nil] if found

    cmd =
      if Gem.win_platform? then 'warlock'
      elsif RUBY_PLATFORM.include?('darwin') then '/Applications/Warlock.app/Contents/MacOS/Warlock'
      else '/usr/bin/warlock'
      end
    ["#{cmd} --host localhost --port %port% --key %key%", nil]
  end

  # Saved GemStone and DragonRealms logins without passwords, each from the Lich folder used for
  # its game: [{char_name:, game_code:, game_name:, user_id:, frontend:, custom_launch:, custom_launch_dir:}]
  # frontend is the one Chrono shows ("warlock" for a Warlock custom launch).
  # (A login saved in the other game's folder isn't one Chrono would start, so it's left out.)
  def entries
    lich_folders.flat_map { |dir| in_folder(dir) { entries_here } }
  end

  def entries_here
    list =
      case backend
      when :yaml then File.exist?(yaml_file) ? yaml_entries : []
      else
        (File.exist?(dat_file) ? dat_entries : []).map do |e|
          e.reject { |k, _| k == :password }.merge(frontend: shown_frontend(e[:frontend], e[:custom_launch]))
        end
      end
    list.select { |e| GAME_NAMES.key?(e[:game_code].to_s) && mine?(e[:game_code]) }
  end

  # Whether a game's logins belong to the Lich folder in use.
  def mine?(game_code) = lich_dir_for(game_code) == lich_dir

  def yaml_entries
    data = load_yaml
    (data['accounts'] || {}).flat_map do |account, info|
      Array(info && info['characters']).map do |c|
        { char_name: c['char_name'].to_s, game_code: c['game_code'].to_s, game_name: c['game_name'].to_s,
          user_id: account.to_s, frontend: shown_frontend(c['frontend'], c['custom_launch']),
          custom_launch: c['custom_launch'], custom_launch_dir: c['custom_launch_dir'] }
      end
    end
  end

  def load_yaml
    data = YAML.safe_load_file(yaml_file, permitted_classes: [Symbol])
    fail! "#{yaml_file} isn't in the format Chrono expects." unless data.is_a?(Hash)
    data
  rescue Psych::Exception => e
    fail! "Couldn't read #{yaml_file}: #{e.message}"
  end

  def dat_entries
    data = Marshal.load(File.binread(dat_file).unpack1('m'))
    fail! "#{dat_file} did not contain a list of characters." unless data.is_a?(Array)
    data
  rescue Fail
    raise
  rescue StandardError => e
    fail! "Couldn't read #{dat_file}: #{e.class}: #{e.message}"
  end

  # ---------- backups and writing ----------

  # this Lich folder's, so each game's are kept apart
  def backup_dir = File.join(data_dir, 'chrono', 'backups')

  # Backups hold passwords, so only the player's own account can read them (on Linux and Mac).
  def backup!(file)
    return unless File.exist?(file)
    ensure_state_dir
    FileUtils.mkdir_p(backup_dir, mode: 0o700)
    File.chmod(0o700, File.dirname(backup_dir), backup_dir) unless Gem.win_platform?
    FileUtils.install(file, File.join(backup_dir, "#{File.basename(file)}.#{Time.now.strftime('%Y%m%d-%H%M%S-%L')}"), mode: 0o600)
    old = Dir.glob(File.join(backup_dir, "#{File.basename(file)}.*")).sort
    old.first([old.size - KEEP_BACKUPS, 0].max).each { |f| File.delete(f) }
  end

  # After a password change or removing an account, older backups still hold the old password
  # (or the removed account's), so they're deleted; a backup of the file as it is now is kept.
  def forget_old_backups!
    [yaml_file, dat_file].each do |file|
      Dir.glob(File.join(backup_dir, "#{File.basename(file)}.*")).each { |f| File.delete(f) }
      backup!(file)
    end
  rescue SystemCallError => e
    log "Couldn't delete older backups of the saved logins: #{e.message}"
  end

  # Replaces file with content in one step, keeping its permissions (Lich makes these files
  # readable by the player only): a new, uniquely named file, written out fully, then swapped in.
  def write_atomically(file, content)
    mode = (File.stat(file).mode & 0o777 rescue 0o600)
    tmp = "#{file}.chrono-#{SecureRandom.hex(4)}.tmp"
    File.open(tmp, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, mode) do |f|
      f.write(content)
      f.flush
      f.fsync
    end
    File.chmod(mode, tmp) # (the umask may have trimmed it)
    File.rename(tmp, file)
  rescue StandardError
    File.delete(tmp) if tmp && File.exist?(tmp)
    raise
  end

  def write_dat(list)
    backup!(dat_file)
    write_atomically(dat_file, [Marshal.dump(list)].pack('m'))
  end

  # Lich 5.25.0 and newer read the password from standard input with --password-stdin, which keeps
  # it out of the command line (where other programs can see it while Lich runs). 5.26.0 stops
  # accepting it on the command line at all. Older Lich only takes it on the command line.
  STDIN_PASSWORD_LICH = Gem::Version.new('5.25.0')

  def lich_password_stdin?
    v = lich_version
    return true if v && (Gem::Version.new(v) >= STDIN_PASSWORD_LICH rescue false)
    # a development or pre-release Lich that already has it
    src = File.read(File.join(lich_dir, 'lib', 'common', 'cli', 'cli_orchestration.rb')) rescue ''
    src.include?('--password-stdin')
  end

  # Runs one of Lich's account commands. The password (secret:), when Lich supports it, is given
  # on standard input with --password-stdin in its place; otherwise in its place on the command line.
  def run_lich(*args, secret: nil)
    fail! "This Lich has no command for changing saved logins (needs Lich 5.13 or newer; found #{lich_version || 'unknown'})." unless lich_has_cli?
    backup!(yaml_file)
    stdin = ''
    if secret && lich_password_stdin?
      args = args.map { |a| a.equal?(secret) ? '--password-stdin' : a } # same place: Lich reads it as the flag
      stdin = "#{secret}\n"
    end
    cmd = [rubyw_path, File.join(lich_dir, 'lich.rbw'), *args]
    out, status = Open3.capture2e(*cmd, chdir: lich_dir, stdin_data: stdin)
    out = out.force_encoding(Encoding::UTF_8).scrub
    out = out.gsub(secret, '********') if secret && !secret.empty?
    [out.strip, status]
  end

  def lich_error(out, what)
    line = out.lines.map(&:strip).find { |l| l.start_with?('error:') } || out.lines.last.to_s.strip
    fail! "Lich couldn't #{what}: #{line.sub(/\Aerror:\s*/, '')}"
  end

  # ---------- changes ----------

  # Saves the picked characters (from ChronoEAccess.list_characters) for an account.
  # picked: [{game_code:, game_name:, char_name:}]
  # frontend "warlock" saves a Warlock custom launch: launch (the command) and launch_dir default
  # to warlock_launch.
  def add(account, password, picked, frontend, launch: nil, launch_dir: nil)
    fail! 'Pick at least one character.' if picked.empty?
    account = account.strip
    custom = nil
    if frontend == WARLOCK
      default_cmd, default_dir = warlock_launch
      cmd = launch.to_s.strip.empty? ? default_cmd : launch.to_s.strip
      dir = launch_dir.nil? ? default_dir : (launch_dir.to_s.strip.empty? ? nil : launch_dir.to_s.strip)
      unless cmd.include?('%port%') && cmd.include?('%key%')
        fail! 'The Warlock command must include %port% and %key% (Lich fills them in when the game starts).'
      end
      fail! 'The Warlock command must mention warlock, so Lich and Chrono can tell it apart.' unless warlock_launch?(cmd)
      custom = [cmd, dir]
    end
    # each character goes into the Lich folder used for its game
    picked.group_by { |c| folder_for(c[:game_code]) }.sum do |dir, chars|
      in_folder(dir) do
        if backend == :yaml
          add_yaml(account, password, chars, frontend, custom)
        else
          add_dat(account, password, chars, frontend, custom)
        end
      end
    end
  end

  def add_dat(account, password, picked, frontend, launch = nil)
    list = File.exist?(dat_file) ? dat_entries : []
    added = 0
    picked.each do |c|
      next if list.any? do |e|
        e[:char_name].to_s.casecmp?(c[:char_name]) && e[:game_code] == c[:game_code] &&
          shown_frontend(e[:frontend], e[:custom_launch]) == frontend
      end
      list << { char_name: c[:char_name].capitalize, game_code: c[:game_code],
                game_name: GAME_NAMES[c[:game_code]] || c[:game_name], user_id: account.downcase,
                password: password, frontend: launch ? WARLOCK_BASE_FRONTEND : frontend,
                custom_launch: launch&.first, custom_launch_dir: launch&.last }
      added += 1
    end
    # one password per account: keep every saved character on this account in step
    list.each { |e| e[:password] = password if e[:user_id].to_s.casecmp?(account) }
    write_dat(list)
    log "LOGINS saved #{added} character(s) for account #{account} in entry.dat"
    added
  end

  def add_yaml(account, password, picked, frontend, launch = nil)
    lich_frontend = launch ? WARLOCK_BASE_FRONTEND : frontend
    existing = File.exist?(yaml_file) ? (load_yaml['accounts'] || {}) : {}
    key = existing.keys.find { |k| k.to_s.casecmp?(account) }
    if key
      # account already saved: refresh its password (just checked with Simutronics), then add characters
      out, status = run_lich('--change-account-password', key, password, secret: password)
      lich_error(out, 'update the password') unless status.success?
      stored = yaml_entries.select { |e| e[:user_id].casecmp?(key) }
      todo = picked.reject { |c| stored.any? { |e| e[:char_name].casecmp?(c[:char_name]) && e[:game_code] == c[:game_code] && e[:frontend] == frontend } }
      if launch
        # Lich's add-character command can't save a custom launch, so Chrono adds these the way
        # Lich's own account manager does: a new character record, no passwords involved.
        add_yaml_characters(key, todo, launch) unless todo.empty?
      else
        todo.each do |c|
          out, status = run_lich('--add-character', key, c[:char_name], '--game-code', c[:game_code], '--frontend', lich_frontend)
          lich_error(out, "add #{c[:char_name]}") unless status.success?
        end
      end
      added = todo.size
    else
      # new account: Lich saves every character on it, then the ones not picked are removed
      out, status = run_lich('--add-account', account, password, '--frontend', lich_frontend, secret: password)
      lich_error(out, 'add the account') unless status.success?
      key = (load_yaml['accounts'] || {}).keys.find { |k| k.to_s.casecmp?(account) } or
        fail! "Lich reported success, but account #{account} isn't in entry.yaml."
      keep = picked.map { |c| [c[:char_name].downcase, c[:game_code]] }
      remove_yaml_characters(key) { |c| !keep.include?([c['char_name'].to_s.downcase, c['game_code']]) }
      set_yaml_launch(key, launch) if launch
      added = picked.size
    end
    log "LOGINS saved #{added} character(s) for account #{account} through Lich"
    added
  end

  # Changes the account's password in every Lich folder it's saved in.
  def change_password(account, password)
    dirs = folders_with(account)
    fail! "Account #{account} isn't saved." if dirs.empty?
    dirs.each { |dir| in_folder(dir) { change_password_here(account, password) } }
    log "LOGINS changed the saved password for account #{account}"
    Rewards.github_password_changed(account) if defined?(Rewards)
  end

  def change_password_here(account, password)
    if backend == :yaml
      key = (load_yaml['accounts'] || {}).keys.find { |k| k.to_s.casecmp?(account) } or
        fail! "Account #{account} isn't saved."
      out, status = run_lich('--change-account-password', key, password, secret: password)
      lich_error(out, 'change the password') unless status.success?
    else
      list = dat_entries
      hits = list.select { |e| e[:user_id].to_s.casecmp?(account) }
      fail! "Account #{account} isn't saved." if hits.empty?
      hits.each { |e| e[:password] = password }
      write_dat(list)
    end
    forget_old_backups!
  end

  # Removes every saved login for this character in this game (all frontends).
  # frontend: only the saved login for that frontend (as Chrono shows it, e.g. "warlock");
  # nil removes the character's saved logins for every frontend.
  def remove(char_name, game_code, account, frontend: nil)
    in_folder(folder_for(game_code)) { remove_here(char_name, game_code, account, frontend: frontend) }
  end

  def remove_here(char_name, game_code, account, frontend: nil)
    fe_ok = ->(fe, cl) { frontend.nil? || shown_frontend(fe, cl) == frontend }
    if backend == :yaml
      key = (load_yaml['accounts'] || {}).keys.find { |k| k.to_s.casecmp?(account) } or
        fail! "Account #{account} isn't saved."
      n = remove_yaml_characters(key) do |c|
        c['char_name'].to_s.casecmp?(char_name) && c['game_code'] == game_code && fe_ok.call(c['frontend'], c['custom_launch'])
      end
    else
      list = dat_entries
      before = list.size
      list.reject! do |e|
        e[:char_name].to_s.casecmp?(char_name) && e[:game_code] == game_code && e[:user_id].to_s.casecmp?(account) &&
          fe_ok.call(e[:frontend], e[:custom_launch])
      end
      n = before - list.size
      write_dat(list) if n.positive?
    end
    fail! "#{char_name} isn't saved for account #{account}." if n.zero?
    log "LOGINS removed #{char_name} (#{game_code}) from account #{account}"
    n
  end

  # Removes an account and all its saved characters (what Lich's "Remove" does on an account row),
  # in every Lich folder it's saved in.
  def remove_account(account)
    dirs = folders_with(account)
    fail! "Account #{account} isn't saved." if dirs.empty?
    dirs.each { |dir| in_folder(dir) { remove_account_here(account) } }
    log "LOGINS removed account #{account} and its characters"
  end

  # In a Lich folder that also holds the other game's logins for this account (ones Chrono doesn't
  # use from here, so doesn't show), only this folder's game's characters are removed.
  def remove_account_here(account)
    if backend == :yaml
      key = (load_yaml['accounts'] || {}).keys.find { |k| k.to_s.casecmp?(account) } or
        fail! "Account #{account} isn't saved."
      chars = Array(load_yaml.dig('accounts', key, 'characters'))
      if chars.all? { |c| mine?(c['game_code']) }
        edit_yaml { |data| data['accounts'].delete(key) }
      else
        remove_yaml_characters(key) { |c| mine?(c['game_code']) }
      end
    else
      list = dat_entries
      before = list.size
      list.reject! { |e| e[:user_id].to_s.casecmp?(account) && mine?(e[:game_code]) }
      fail! "Account #{account} isn't saved." if list.size == before
      write_dat(list)
    end
    forget_old_backups!
  end

  # Changes one saved login's frontend (from -> to, as Chrono shows them). "warlock" saves
  # Warlock's launch command; any other frontend clears a custom launch. Passwords aren't touched.
  def set_frontend(account, char_name, game_code, from, to)
    return if from == to

    edit_login(account, char_name, game_code, from, to)
  end

  # Edits one saved login: its frontend (from -> to, as Chrono shows them) and, for Warlock, its
  # launch command (launch: nil keeps the current one, or uses warlock_launch when switching to
  # Warlock). Passwords aren't touched.
  def edit_login(account, char_name, game_code, from, to, launch: nil)
    in_folder(folder_for(game_code)) { edit_login_here(account, char_name, game_code, from, to, launch: launch) }
  end

  def edit_login_here(account, char_name, game_code, from, to, launch: nil)
    if to == WARLOCK && launch
      launch = launch.to_s.strip
      unless launch.include?('%port%') && launch.include?('%key%') && warlock_launch?(launch)
        fail! 'The Warlock command must mention warlock and include %port% and %key%.'
      end
    end
    rec = lambda do |fe, cl, dir|
      if to == WARLOCK
        if launch then [WARLOCK_BASE_FRONTEND, launch, from == WARLOCK ? dir : warlock_launch[1]]
        elsif from == WARLOCK then [fe, cl, dir]
        else
          cmd, d = warlock_launch
          [WARLOCK_BASE_FRONTEND, cmd, d]
        end
      else
        [to, nil, nil]
      end
    end
    same = ->(name, code) { name.to_s.casecmp?(char_name) && code == game_code }
    if backend == :yaml
      key = (load_yaml['accounts'] || {}).keys.find { |k| k.to_s.casecmp?(account) } or
        fail! "Account #{account} isn't saved."
      chars = load_yaml.dig('accounts', key, 'characters') || []
      if from != to && chars.any? { |c| same.call(c['char_name'], c['game_code']) && shown_frontend(c['frontend'], c['custom_launch']) == to }
        fail! "#{char_name} is already saved for #{to}."
      end
      changed = false
      edit_yaml do |data|
        data.dig('accounts', key, 'characters').each do |c|
          next unless same.call(c['char_name'], c['game_code']) && shown_frontend(c['frontend'], c['custom_launch']) == from
          next if changed

          c['frontend'], c['custom_launch'], c['custom_launch_dir'] = rec.call(c['frontend'], c['custom_launch'], c['custom_launch_dir'])
          changed = true
        end
      end
    else
      list = dat_entries
      mine = list.select { |e| e[:user_id].to_s.casecmp?(account) && same.call(e[:char_name], e[:game_code]) }
      fail! "#{char_name} is already saved for #{to}." if from != to && mine.any? { |e| shown_frontend(e[:frontend], e[:custom_launch]) == to }
      e = mine.find { |x| shown_frontend(x[:frontend], x[:custom_launch]) == from }
      changed = !e.nil?
      if e
        e[:frontend], e[:custom_launch], e[:custom_launch_dir] = rec.call(e[:frontend], e[:custom_launch], e[:custom_launch_dir])
        write_dat(list)
      end
    end
    fail! "#{char_name} (#{from}) isn't saved for account #{account}." unless changed
    log "LOGINS #{char_name} (#{game_code}, #{account}): #{from == to ? "#{to} launch updated" : "frontend #{from} -> #{to}"}"
  end

  # Adds character records with a custom launch to an account in entry.yaml (same fields Lich writes).
  def add_yaml_characters(account_key, picked, launch)
    edit_yaml do |data|
      chars = (data['accounts'][account_key]['characters'] ||= [])
      picked.each do |c|
        chars << { 'char_name' => c[:char_name].to_s.strip.split.map(&:capitalize).join(' '),
                   'game_code' => c[:game_code], 'game_name' => GAME_NAMES[c[:game_code]] || c[:game_name],
                   'frontend' => WARLOCK_BASE_FRONTEND, 'custom_launch' => launch[0], 'custom_launch_dir' => launch[1] }
      end
    end
  end

  # Gives every character on the account the custom launch (used right after adding a new account).
  def set_yaml_launch(account_key, launch)
    edit_yaml do |data|
      (data.dig('accounts', account_key, 'characters') || []).each do |c|
        c['frontend'] = WARLOCK_BASE_FRONTEND
        c['custom_launch'] = launch[0]
        c['custom_launch_dir'] = launch[1]
      end
    end
  end

  def edit_yaml
    data = load_yaml
    yield data
    backup!(yaml_file)
    write_atomically(yaml_file, YAML.dump(data))
  end

  # Removing a character doesn't touch passwords or encryption settings, so Chrono edits
  # entry.yaml directly, keeping everything else exactly as it was.
  def remove_yaml_characters(account_key)
    data = load_yaml
    chars = data.dig('accounts', account_key, 'characters') || []
    before = chars.size
    chars.reject! { |c| yield(c) }
    removed = before - chars.size
    if removed.positive?
      backup!(yaml_file)
      write_atomically(yaml_file, YAML.dump(data))
    end
    removed
  end
end
