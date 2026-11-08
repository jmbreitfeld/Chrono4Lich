# chrono_config.rb - where Lich is installed, saved next to the Chrono4Lich files.
#
# Order used to find the Lich folder:
#   1. CHRONO_LICH_DIR environment variable (for testing)
#   2. chrono_config.json in the Chrono4Lich folder (set by the window, or by
#      "chrono set-lich-dir <folder>")
#   3. the folder saved by lichsched, Chrono's old name, if it's still valid
#   4. auto-detect, if exactly one Lich install is found (then saved to the config)

require 'json'
require 'fileutils'

module ChronoConfig
  APP_DIR     = __dir__
  CONFIG_FILE = File.join(APP_DIR, 'chrono_config.json')

  module_function

  def windows?
    Gem.win_platform?
  end

  # Paths are kept with / internally; show them the way the system writes them.
  def disp(path)
    windows? ? path.to_s.tr('/', '\\') : path.to_s
  end

  def example_lich_dir
    windows? ? 'C:\\path\\to\\Lich5' : '~/lich5'
  end

  def load
    return {} unless File.exist?(CONFIG_FILE)
    data = JSON.parse(File.read(CONFIG_FILE))
    data.is_a?(Hash) ? data : {}
  rescue JSON::ParserError => e
    raise "#{CONFIG_FILE} is damaged and can't be read (#{e.message}). Delete it and pick the Lich folder again."
  end

  def save(changes)
    data = load.merge(changes)
    tmp = CONFIG_FILE + '.tmp'
    File.write(tmp, JSON.pretty_generate(data))
    File.rename(tmp, CONFIG_FILE)
  end

  def normalize(dir)
    File.expand_path(dir.to_s.strip.delete('"')).tr('\\', '/').chomp('/')
  end

  # A Lich folder has lich.rbw in it.
  def valid_lich_dir?(dir)
    return false if dir.to_s.strip.empty?
    File.file?(File.join(normalize(dir), 'lich.rbw'))
  end

  def why_invalid(dir)
    d = normalize(dir)
    return "#{d} doesn't exist." unless File.directory?(d)
    "#{d} has no lich.rbw in it, so it isn't a Lich folder."
  end

  # Places Lich is commonly installed, plus the folders above this app.
  def candidates
    list = []
    dir = APP_DIR
    4.times do
      list << dir
      parent = File.dirname(dir)
      break if parent == dir
      dir = parent
    end
    list += windows? ? windows_candidates : linux_candidates
    list.map { |d| normalize(d) }.uniq
  end

  def linux_candidates
    home = Dir.home
    names = %w[lich5 Lich5 lich Lich]
    bases = [home, File.join(home, 'Desktop'), File.join(home, 'Documents'), File.join(home, 'games'),
             File.join(home, 'Games'), File.join(home, '.local', 'share'), '/opt']
    list = bases.product(names).map { |b, n| File.join(b, n) }
    list += names.map { |n| File.join(home, ".#{n}") }
    list
  end

  def windows_candidates
    home = ENV['USERPROFILE'] || Dir.home
    list = []
    desktops = [File.join(home, 'Desktop')]
    desktops << File.join(ENV['OneDrive'], 'Desktop') if ENV['OneDrive']
    desktops += Dir.glob(File.join(home, 'OneDrive*', 'Desktop'))
    desktops.each { |d| list += [File.join(d, 'Lich5'), File.join(d, 'Lich')] }
    list += [File.join(home, 'Lich5'), File.join(home, 'Documents', 'Lich5'), File.join(home, 'Lich'),
             'C:/Lich5', 'C:/Lich', 'C:/Ruby4Lich5/Lich5']
    list += Dir.glob('C:/Ruby4Lich5/*/Lich5')
    list
  end

  def detect
    candidates.select { |d| valid_lich_dir?(d) }
  end

  # Chrono used to be called lichsched. Reuse the Lich folder it had saved, if it's still valid.
  def legacy_config_files
    list = [File.join(APP_DIR, 'lichsched_config.json')]
    if windows?
      list << File.join(ENV['LOCALAPPDATA'], 'lichsched', 'lichsched_config.json') if ENV['LOCALAPPDATA']
    else
      list << File.join(ENV['XDG_DATA_HOME'] || File.join(Dir.home, '.local', 'share'), 'lichsched', 'lichsched_config.json')
    end
    list
  end

  def legacy_lich_dir
    legacy_config_files.each do |f|
      next unless File.exist?(f)
      dir = (JSON.parse(File.read(f)) rescue {})['lich_dir']
      return normalize(dir) if dir && valid_lich_dir?(dir)
    end
    nil
  end

  # Returns the Lich folder, or nil if it isn't set and can't be found unambiguously.
  # Raises if a saved folder is no longer a Lich folder, so that isn't silent.
  def lich_dir
    if ENV['CHRONO_LICH_DIR'] && !ENV['CHRONO_LICH_DIR'].empty?
      return normalize(ENV['CHRONO_LICH_DIR'])
    end
    saved = load['lich_dir']
    if saved
      raise "The saved Lich folder isn't valid any more: #{why_invalid(saved)}" unless valid_lich_dir?(saved)
      return normalize(saved)
    end
    if (old = legacy_lich_dir)
      save('lich_dir' => old)
      return old
    end
    found = detect
    return nil unless found.size == 1
    save('lich_dir' => found.first)
    found.first
  end
end
