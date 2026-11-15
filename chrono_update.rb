# chrono_update.rb - "Update now": downloads the newest Chrono release for this system, checks it
# against the release's SHA256SUMS.txt, then starts it once Chrono has closed. Loaded by chrono.rb.
#
#   Windows (installed with the setup .exe): runs the new Chrono4Lich-setup-X.exe; its last page
#     offers "Open Chrono now".
#   Linux: unpacks Chrono4Lich-linux.tar.gz and runs its install.sh with the same Ruby, then
#     reopens Chrono.
#   Windows copies set up from the zip can't update this way (the installer would make a second
#     copy elsewhere), so for those Chrono opens the release page instead.

require 'digest'
require 'fileutils'
require 'net/http'
require 'tmpdir'
require 'uri'

module ChronoUpdate
  class Error < StandardError; end

  SUMS = 'SHA256SUMS.txt'

  module_function

  # Set up with the Windows installer (it leaves uninstall.exe), or on Linux (install.sh)?
  def can_update_here?
    return File.exist?(File.join(ChronoConfig::APP_DIR, 'uninstall.exe')) if ChronoConfig.windows?

    true
  end

  # The release file for this system: {name:, url:, size:} or nil
  def asset_for_here(release)
    want = ChronoConfig.windows? ? /\AChrono4Lich-setup-[\d.]+\.exe\z/i : /\AChrono4Lich-linux\.tar\.gz\z/i
    release[:assets].find { |a| a[:name].match?(want) }
  end

  def update_dir
    base = ChronoConfig.windows? ? (ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir) : File.join(ENV['XDG_CACHE_HOME'] || File.join(Dir.home, '.cache'), 'chrono')
    File.join(base, 'Chrono4Lich-update').tap { |d| FileUtils.mkdir_p(d) }
  end

  # Downloads url to path, following GitHub's redirects to its file servers.
  def download(url, path, progress: ->(_done, _total) {})
    5.times do
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 15, read_timeout: 60) do |h|
        req = Net::HTTP::Get.new(uri)
        req['User-Agent'] = ChronoGitHub::USER_AGENT
        req['Accept'] = 'application/octet-stream'
        h.request(req) do |res|
          case res
          when Net::HTTPRedirection
            url = URI.join(url, res['location']).to_s
          when Net::HTTPSuccess
            total = res['content-length'].to_i
            done = 0
            File.open("#{path}.part", 'wb') do |f|
              res.read_body do |chunk|
                f.write(chunk)
                done += chunk.bytesize
                progress.call(done, total)
              end
            end
            File.rename("#{path}.part", path)
            return path
          else
            raise Error, "GitHub answered #{res.code} for #{File.basename(uri.path)}."
          end
        end
      end
    end
    raise Error, 'Too many redirects while downloading the update.'
  rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
    raise Error, "Couldn't download the update: #{e.message}"
  end

  # Downloads this system's file from the release and checks it. Returns its path.
  def fetch(release, progress: ->(_done, _total) {})
    asset = asset_for_here(release) or
      raise Error, "Release #{release[:version]} has no download for #{ChronoConfig.windows? ? 'Windows' : 'Linux'}."
    sums = release[:assets].find { |a| a[:name] == SUMS } or
      raise Error, "Release #{release[:version]} has no #{SUMS}, so the download can't be checked. Use the release page."
    dir = update_dir
    Dir.glob(File.join(dir, '*')).each { |f| FileUtils.rm_rf(f) } # earlier downloads
    sums_path = download(sums[:url], File.join(dir, SUMS))
    expected = File.readlines(sums_path).map(&:split).find { |_h, n| n.to_s.delete_prefix('*') == asset[:name] }&.first
    raise Error, "#{SUMS} doesn't list #{asset[:name]}." unless expected

    path = download(asset[:url], File.join(dir, asset[:name]), progress: progress)
    actual = Digest::SHA256.file(path).hexdigest
    unless actual.casecmp?(expected)
      File.delete(path)
      raise Error, "The download doesn't match the release's checksum (#{SUMS}), so it wasn't used. Try again, or use the release page."
    end
    log "UPDATE downloaded and checked #{asset[:name]} (#{File.size(path)} bytes)"
    path
  end

  # Starts the downloaded update in a separate process that outlives Chrono. Chrono should close
  # right after this.
  def start!(path)
    if ChronoConfig.windows?
      pid = Process.spawn(path, chdir: File.dirname(path), new_pgroup: true)
      Process.detach(pid)
      log "UPDATE started #{File.basename(path)}"
      return
    end

    work = File.join(File.dirname(path), 'unpacked')
    FileUtils.rm_rf(work)
    FileUtils.mkdir_p(work)
    raise Error, "Couldn't unpack #{File.basename(path)}." unless system('tar', 'xzf', path, '-C', work)

    src = File.join(work, 'Chrono4Lich')
    raise Error, 'The download has no install.sh.' unless File.exist?(File.join(src, 'install.sh'))

    ruby = RbConfig.ruby
    app = File.join(ENV['XDG_DATA_HOME'] || File.join(Dir.home, '.local', 'share'), 'Chrono4Lich')
    log_file = File.join(File.dirname(path), 'install.log')
    q = ->(x) { "'#{x.to_s.gsub("'", %q('\\\\''))}'" }
    relaunch = ENV['CHRONO_UPDATE_NO_RELAUNCH'] == '1' ? 'true' : # (testing only)
                 "{ #{q.call(ruby)} #{q.call(File.join(app, 'chrono_gui.rbw'))} >/dev/null 2>&1 & }"
    script = "sleep 2; cd #{q.call(src)} && bash ./install.sh --ruby #{q.call(ruby)} --yes > #{q.call(log_file)} 2>&1 " \
             "&& #{relaunch} " \
             "|| { command -v notify-send >/dev/null && notify-send 'Chrono update failed' 'See #{log_file}'; }"
    pid = Process.spawn('bash', '-c', script, chdir: src, pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL)
    Process.detach(pid)
    log "UPDATE running install.sh from #{File.basename(path)} (log: #{log_file})"
    pid
  end
end
