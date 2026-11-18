# chrono_update.rb - "Update now": downloads the newest Chrono release for this system, checks it,
# then starts it once Chrono has closed. Loaded by chrono.rb.
#
# Checks, all of which must pass or nothing is run:
#   - SHA256SUMS.txt (the release's list of file checksums) carries a valid signature,
#     SHA256SUMS.txt.sig, made by Chrono's release key when the release was built. The public half
#     of that key is built into Chrono (RELEASE_KEY), so a file swapped on GitHub, or anywhere on
#     the way, is refused even if its checksum list was swapped too.
#   - the download matches its checksum in that list;
#   - its name (Windows) or the Chrono inside it (Linux, Mac) is the version being installed, and
#     that version is newer than this one, so an older release can't be passed off as new;
#   - Windows: if the installer is code-signed, the signature is valid and is the expected signer's.
# Downloads only come over https from GitHub's own servers, and stop at the size GitHub listed.
#
#   Windows (installed with the setup .exe): runs the new Chrono4Lich-setup-X.exe; its last page
#     offers "Open Chrono now".
#   Linux: unpacks Chrono4Lich-linux.tar.gz and, once Chrono has closed, runs its install.sh with
#     the same Ruby, then reopens Chrono.
#   Mac: unpacks Chrono4Lich-mac.tar.gz; a Terminal window runs its install.sh with the same Ruby
#     once Chrono has closed (macOS would end a process Chrono left behind), then reopens Chrono.
#   Windows copies set up from the zip can't update this way (the installer would make a second
#     copy elsewhere), so for those Chrono opens the release page instead.

require 'digest'
require 'fileutils'
require 'net/http'
require 'tmpdir'
require 'uri'
require 'openssl'

module ChronoUpdate
  class Error < StandardError; end

  SUMS = 'SHA256SUMS.txt'
  SIG  = 'SHA256SUMS.txt.sig'
  # Public half of Chrono's release-signing key (Ed25519, base64 of its DER form). build.sh fills
  # this in from release-signing.pub; a copy built without it can't update itself.
  RELEASE_KEY = ''
  # Who signs the Windows installer (SignPath's free program for open-source projects).
  WINDOWS_SIGNER = /SignPath Foundation/i
  DOWNLOAD_HOSTS = %w[github.com objects.githubusercontent.com release-assets.githubusercontent.com].freeze
  MAX_SIZE = 200 * 1024 * 1024 # no Chrono download comes anywhere near this

  module_function

  # Mac: where install.sh put Chrono.app (it records it), or nil.
  def mac_app
    path = File.read(File.join(ChronoConfig::APP_DIR, 'mac_app')).strip
    File.directory?(path) ? path : nil
  rescue SystemCallError
    nil
  end

  # Set up with the Windows installer (it leaves uninstall.exe), or on Linux (install.sh)?
  def can_update_here?
    return File.exist?(File.join(ChronoConfig::APP_DIR, 'uninstall.exe')) if ChronoConfig.windows?

    true
  end

  # The release file for this system: {name:, url:, size:} or nil. The Windows installer's name
  # must carry the release's own version.
  def asset_for_here(release)
    want = if ChronoConfig.windows? then ["Chrono4Lich-setup-#{release[:version]}.exe"]
           elsif ChronoConfig.mac? then %w[Chrono4Lich-mac.tar.gz Chrono4Lich-linux.tar.gz] # same files
           else %w[Chrono4Lich-linux.tar.gz]
           end
    want.each do |name|
      found = release[:assets].find { |a| a[:name] == name }
      return found if found
    end
    nil
  end

  # Only https, only GitHub's own servers (a test setup with CHRONO_DEV=1 may use a local one).
  def allowed_url?(url)
    uri = URI(url.to_s)
    return true if ENV['CHRONO_DEV'] == '1' && uri.is_a?(URI::HTTP) && %w[127.0.0.1 localhost].include?(uri.host)

    uri.is_a?(URI::HTTPS) && DOWNLOAD_HOSTS.include?(uri.host.to_s.downcase)
  rescue URI::InvalidURIError
    false
  end

  def system_name
    return 'Windows' if ChronoConfig.windows?
    return 'Mac' if ChronoConfig.mac?

    'Linux'
  end

  def update_dir
    base = ChronoConfig.windows? ? (ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir) : File.join(ENV['XDG_CACHE_HOME'] || File.join(Dir.home, '.cache'), 'chrono')
    File.join(base, 'Chrono4Lich-update').tap { |d| FileUtils.mkdir_p(d) }
  end

  # Downloads url to path, following GitHub's redirects to its file servers. Stops past max bytes.
  def download(url, path, max: MAX_SIZE, progress: ->(_done, _total) {})
    max = MAX_SIZE unless max.is_a?(Integer) && max.positive? && max <= MAX_SIZE
    5.times do
      raise Error, "The update download pointed somewhere other than GitHub (#{url[0, 80]}), so it wasn't used." unless allowed_url?(url)

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
            raise Error, 'The update download is bigger than GitHub said, so it wasn\'t used.' if total > max
            done = 0
            File.open("#{path}.part", 'wb') do |f|
              res.read_body do |chunk|
                done += chunk.bytesize
                raise Error, 'The update download is bigger than GitHub said, so it wasn\'t used.' if done > max
                f.write(chunk)
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
    FileUtils.rm_f("#{path}.part")
    raise Error, "Couldn't download the update: #{e.message}"
  rescue Error
    FileUtils.rm_f("#{path}.part")
    raise
  end

  def release_key
    return nil if RELEASE_KEY.empty?

    OpenSSL::PKey.read(RELEASE_KEY.unpack1('m0'))
  rescue OpenSSL::PKey::PKeyError, ArgumentError
    nil
  end

  # True if sig is the release key's signature of data.
  def signed?(data, sig)
    key = release_key or return false
    key.verify(nil, sig, data)
  rescue OpenSSL::PKey::PKeyError, NotImplementedError, ArgumentError, TypeError
    false # (also: a Ruby whose OpenSSL can't check Ed25519 signatures)
  end

  # Downloads this system's file from the release and checks it. Returns its path.
  def fetch(release, current: CHRONO_VERSION, progress: ->(_done, _total) {})
    use_page = 'Use the release page to update instead.'
    raise Error, "This copy of Chrono has no release key to check updates with. #{use_page}" unless release_key
    unless ChronoGitHub.newer?(release[:version], current)
      raise Error, "Release #{release[:version]} isn't newer than this Chrono (#{current})."
    end
    asset = asset_for_here(release) or
      raise Error, "Release #{release[:version]} has no download for #{system_name}."
    sums = release[:assets].find { |a| a[:name] == SUMS }
    sig = release[:assets].find { |a| a[:name] == SIG }
    raise Error, "Release #{release[:version]} has no signed checksum list, so the download can't be checked. #{use_page}" unless sums && sig

    dir = update_dir
    Dir.glob(File.join(dir, '*')).each { |f| FileUtils.rm_rf(f) } # earlier downloads
    sums_path = download(sums[:url], File.join(dir, SUMS), max: 64 * 1024)
    sig_path = download(sig[:url], File.join(dir, SIG), max: 4096)
    unless signed?(File.binread(sums_path), File.binread(sig_path))
      raise Error, "The release's checksum list isn't signed with Chrono's release key, so the update wasn't used. #{use_page}"
    end
    expected = File.readlines(sums_path).map(&:split).find { |_h, n| n.to_s.delete_prefix('*') == asset[:name] }&.first
    raise Error, "#{SUMS} doesn't list #{asset[:name]}." unless expected

    path = download(asset[:url], File.join(dir, asset[:name]), max: asset[:size], progress: progress)
    actual = Digest::SHA256.file(path).hexdigest
    unless actual.casecmp?(expected)
      File.delete(path)
      raise Error, "The download doesn't match the release's checksum (#{SUMS}), so it wasn't used. Try again, or use the release page."
    end
    check_windows_signature!(path) if ChronoConfig.windows?
    log "UPDATE downloaded and checked #{asset[:name]} (#{File.size(path)} bytes)"
    path
  end

  # Windows: the installer's own code signature, if it has one, must be valid and SignPath's.
  # (Releases before code signing was set up aren't signed; the signed checksum list covers those.)
  def check_windows_signature!(path)
    ps = "$s = Get-AuthenticodeSignature -LiteralPath $env:P; $s.Status; $s.SignerCertificate.Subject"
    out = IO.popen({ 'P' => path }, ['powershell', '-NoProfile', '-NonInteractive', '-Command', ps], err: File::NULL, &:read).to_s
    status, subject = out.lines.map(&:strip)
    case status
    when 'Valid'
      raise Error, "The installer is signed by someone else (#{subject}), so it wasn't run." unless subject.to_s.match?(WINDOWS_SIGNER)
    when 'NotSigned'
      log 'UPDATE the installer is not code-signed (its signed checksum matched)'
    when nil, ''
      log "UPDATE couldn't read the installer's code signature (PowerShell gave no answer); its signed checksum matched"
    else
      raise Error, "The installer's code signature is #{status}, so it wasn't run. Use the release page."
    end
  rescue SystemCallError
    log "UPDATE couldn't check the installer's code signature (no PowerShell); its signed checksum matched"
  end

  # The version written in an unpacked Chrono's chrono.rb.
  def unpacked_version(src)
    File.read(File.join(src, 'chrono.rb'))[/^CHRONO_VERSION = '([^']+)'/, 1]
  rescue SystemCallError
    nil
  end

  # Unpacks a Linux/Mac download into work/, refusing anything outside Chrono4Lich/ or any link.
  def unpack!(path, work)
    list = IO.popen(['tar', '-tvzf', path], err: File::NULL, &:read).to_s
    raise Error, "Couldn't read #{File.basename(path)}." unless $?.success? && !list.empty?

    list.each_line do |line|
      kind = line[0]
      raise Error, "#{File.basename(path)} contains a link, which Chrono's downloads never do, so it wasn't used." if %w[l h].include?(kind)
      raise Error, "#{File.basename(path)} contains something unexpected, so it wasn't used." unless %w[- d].include?(kind)
    end
    names = IO.popen(['tar', '-tzf', path], err: File::NULL, &:readlines).map(&:chomp)
    bad = names.find { |n| !(n == 'Chrono4Lich/' || n.start_with?('Chrono4Lich/')) || n.split('/').include?('..') }
    raise Error, "#{File.basename(path)} has files outside its Chrono4Lich folder, so it wasn't used." if bad

    ok = system('tar', '--no-same-owner', '--no-same-permissions', '-xzf', path, '-C', work, out: File::NULL, err: File::NULL)
    raise Error, "Couldn't unpack #{File.basename(path)}." unless ok
  end

  # Unpacks a checked Linux/Mac download and makes sure it holds the expected Chrono, newer than
  # this one. Returns its Chrono4Lich folder.
  def unpack_checked!(path, version: nil)
    work = File.join(File.dirname(path), 'unpacked')
    FileUtils.rm_rf(work)
    FileUtils.mkdir_p(work)
    unpack!(path, work)

    src = File.join(work, 'Chrono4Lich')
    raise Error, 'The download has no install.sh.' unless File.exist?(File.join(src, 'install.sh'))
    found = unpacked_version(src)
    if version && found != version
      raise Error, "The download holds Chrono #{found || '(unknown)'}, not #{version}, so it wasn't used."
    end
    unless found && ChronoGitHub.newer?(found, CHRONO_VERSION)
      raise Error, "The download holds Chrono #{found || '(unknown)'}, which isn't newer than this one, so it wasn't used."
    end
    src
  end

  # Mac: hands the install to a Terminal window, then Chrono should close. A process Chrono starts
  # itself can't do it: when an app quits, macOS ends everything it left running (even a job
  # handed to launchd) unless the app is allowed to run in the background, so the installer was
  # stopped before it began. Terminal is an app of its own, so its window carries on: it waits for
  # this Chrono to close, runs install.sh with the same Ruby (as when installing by hand), shows
  # its output, and opens the new Chrono.
  def start_mac!(path, version: nil)
    src = unpack_checked!(path, version: version)
    dir = File.dirname(path)
    log_file = File.join(dir, 'install.log')
    app = File.join(ENV['XDG_DATA_HOME'] || File.join(Dir.home, '.local', 'share'), 'Chrono4Lich')
    q = ->(x) { "'#{x.to_s.gsub("'", %q('\\''))}'" }
    reopen = if ChronoConfig.dev_env('CHRONO_UPDATE_NO_RELAUNCH') == '1' then 'true' # (testing only)
             else "open -a \"$(cat #{q.call(File.join(app, 'mac_app'))})\""
             end
    script = File.join(dir, 'Install Chrono update.command')
    File.write(script, <<~SH)
      #!/bin/bash
      # Made by Chrono's "Update now": installs Chrono #{version || ''} once Chrono has closed, then opens it.
      printf '\\n Updating Chrono to %s. Waiting for Chrono to close...\\n' #{q.call(version || 'the new version')}
      for _ in $(seq 1 120); do kill -0 #{Process.pid} 2>/dev/null || break; sleep 0.5; done
      cd #{q.call(src)} || exit 1
      bash ./install.sh --ruby #{q.call(RbConfig.ruby)} --yes 2>&1 | tee #{q.call(log_file)}
      if [ "${PIPESTATUS[0]}" = 0 ]; then
        #{reopen} || printf '\\n Open Chrono from your Applications folder.\\n'
        printf '\\n Chrono is updated. You can close this window.\\n'
      else
        printf '\\n The update did not finish (see above, or %s).\\n Use the release page to update instead.\\n' #{q.call(log_file)}
      fi
    SH
    File.chmod(0o700, script)
    raise Error, "Couldn't open Terminal to install the update." unless system('open', '-a', 'Terminal', script)

    log "UPDATE installing #{File.basename(path)} in a Terminal window once Chrono closes (log: #{log_file})"
  end

  # Windows and Linux: starts the downloaded update in a separate process that outlives Chrono.
  # Chrono should close right after this. (Mac: start_mac! instead.)
  def start!(path, version: nil)
    if ChronoConfig.windows?
      pid = Process.spawn(path, chdir: File.dirname(path), new_pgroup: true)
      Process.detach(pid)
      log "UPDATE started #{File.basename(path)}"
      return
    end

    src = unpack_checked!(path, version: version)
    ruby = RbConfig.ruby
    app = File.join(ENV['XDG_DATA_HOME'] || File.join(Dir.home, '.local', 'share'), 'Chrono4Lich')
    log_file = File.join(File.dirname(path), 'install.log')
    q = ->(x) { "'#{x.to_s.gsub("'", %q('\\\\''))}'" }
    relaunch = if ChronoConfig.dev_env('CHRONO_UPDATE_NO_RELAUNCH') == '1' then 'true' # (testing only)
               elsif ChronoConfig.mac? then "{ open -a \"$(cat #{q.call(File.join(app, 'mac_app'))})\" || " \
                                            "#{q.call(ruby)} #{q.call(File.join(app, 'chrono_gui.rbw'))} >/dev/null 2>&1 & }"
               else "{ #{q.call(ruby)} #{q.call(File.join(app, 'chrono_gui.rbw'))} >/dev/null 2>&1 & }"
               end
    script = "sleep 2; cd #{q.call(src)} && bash ./install.sh --ruby #{q.call(ruby)} --yes > #{q.call(log_file)} 2>&1 " \
             "&& #{relaunch} " \
             "|| { command -v notify-send >/dev/null && notify-send 'Chrono update failed' #{q.call("See #{log_file}")}; " \
             "command -v osascript >/dev/null && osascript -e 'display alert \"Chrono update failed\" message \"See the install.log in ~/.cache/chrono\"'; }"
    pid = Process.spawn('bash', '-c', script, chdir: src, pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL)
    Process.detach(pid)
    log "UPDATE running install.sh from #{File.basename(path)} (log: #{log_file})"
    pid
  end
end
