# Chrono's checks that run without Lich, a game account or a window. Run from the repository:
#   ruby test/run_tests.rb
# GitHub runs them on every push (.github/workflows/checks.yml).

require 'json'
require 'openssl'
require 'tmpdir'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
$failures = 0
$count = 0

def check(what, ok)
  $count += 1
  return if ok

  $failures += 1
  puts "FAIL: #{what}"
end

def raises?(klass = StandardError)
  yield
  false
rescue klass
  true
end

# ---------- sealed boxes (GitHub secrets) against libsodium's own results ----------
require File.join(ROOT, 'chrono_sealedbox')
JSON.parse(File.read(File.join(__dir__, 'sealedbox_vectors.json')))['vectors'].each_with_index do |v, i|
  got = SealedBox.seal([v['message']].pack('H*'), [v['public_key']].pack('H*'), [v['ephemeral_secret']].pack('H*'))
  check("sealed box vector #{i} (#{v['message'].size / 2} bytes)", got.unpack1('H*') == v['sealed'])
end
# RFC 7748 section 5.2, first X25519 test vector
k = ['a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4'].pack('H*')
u = ['e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c'].pack('H*')
check('X25519 RFC 7748 vector', SealedBox.x25519(k, u).unpack1('H*') == 'c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552')
# RFC 7693 appendix A: BLAKE2b-512("abc")
check('BLAKE2b RFC 7693 vector', SealedBox.blake2b('abc', 64).unpack1('H*').start_with?('ba80a53f981c4d0d6a2797b69f12f6e9'))
check('sealed box refuses a low-order public key', raises?(ArgumentError) { SealedBox.seal('x', "\0".b * 32) })

# ---------- what the schedulers are given ----------
STATE_DIR = Dir.mktmpdir('chrono-test')
class Fail < StandardError; end
def fail!(msg) = raise(Fail, msg)
def log(*) = nil
def ensure_state_dir = FileUtils.mkdir_p(STATE_DIR)
def rubyw_path = '/usr/bin/ruby'
require File.join(ROOT, 'chrono_config')
require File.join(ROOT, 'chrono_schedule')

good = { 'name' => 'Morning run', 'characters' => ['Peggyanne'], 'days' => %w[mon tue], 'login_at' => '07:30', 'logout_at' => '08:00' }
check('a normal schedule passes', !raises?(Fail) { Schedules.check_fields!(good) })
[
  ['name with a line break', good.merge('name' => "x\nExecStart=/bin/sh")],
  ['time with extra text', good.merge('login_at' => "07:30\n[Service]")],
  ['unknown day', good.merge('days' => ['mon', "sun\n"])],
  ['character with a line break', good.merge('characters' => ["Peggy\nanne"])],
  ['no characters', good.merge('characters' => [])],
  ['not a schedule', ['x']]
].each { |what, s| check("refuses a schedule with #{what}", raises?(Fail) { Schedules.check_fields!(s) }) }
check('timer files get one-line descriptions', Schedules.one_line("a\nb\r\x01c") == 'a b c')
check('sd_quote doubles % and escapes quotes', Schedules.sd_quote(%q(a"b\c%d)) == %q("a\"b\\\\c%%d"))
check('xml_escape', Schedules.xml_escape(%(<a & "b">\n)) == '&lt;a &amp; &quot;b&quot;&gt; ')
check('win_quote', Schedules.win_quote('two words') == '"two words"' && Schedules.win_quote('one') == 'one')
xml = Schedules.plist_xml('Label' => "x\ny<z>")
check('plist values are one line and escaped', xml.include?('<string>x y&lt;z&gt;</string>'))
check('task XML refuses a bad job time', raises?(Fail) { Schedules.task_xml(time: '25:00', days: ['mon'], args: [], description: '') })

# ---------- the updater's signature check ----------
CHRONO_VERSION = '1.0.0'
module ChronoGitHub
  USER_AGENT = 'test'
  def self.newer?(a, b) = Gem::Version.new(a) > Gem::Version.new(b)
end
require File.join(ROOT, 'chrono_update')
key = OpenSSL::PKey.generate_key('ED25519')
ChronoUpdate.send(:remove_const, :RELEASE_KEY)
ChronoUpdate.const_set(:RELEASE_KEY, [key.public_to_der].pack('m0'))
sums = "abc  Chrono4Lich-linux.tar.gz\n"
check('a correctly signed checksum list is accepted', ChronoUpdate.signed?(sums, key.sign(nil, sums)))
check('a changed checksum list is refused', !ChronoUpdate.signed?(sums.sub('abc', 'abd'), key.sign(nil, sums)))
check('another key\'s signature is refused', !ChronoUpdate.signed?(sums, OpenSSL::PKey.generate_key('ED25519').sign(nil, sums)))
check('a missing signature is refused', !ChronoUpdate.signed?(sums, ''))
check('downloads only from GitHub over https',
      ChronoUpdate.allowed_url?('https://github.com/x/y/releases/download/v1/a.tar.gz') &&
      ChronoUpdate.allowed_url?('https://release-assets.githubusercontent.com/a') &&
      !ChronoUpdate.allowed_url?('http://github.com/a') &&
      !ChronoUpdate.allowed_url?('https://github.com.evil.example/a') &&
      !ChronoUpdate.allowed_url?('file:///etc/passwd'))
check('sh_quote survives quotes and $', IO.popen(['sh', '-c', "printf '%s' #{ChronoUpdate.sh_quote(%q(it's $HOME "x"))}"], &:read) == %q(it's $HOME "x"))
rel = { version: '1.2.0', assets: [{ name: 'Chrono4Lich-setup-1.1.0.exe' }, { name: 'Chrono4Lich-linux.tar.gz' }] }
unless ChronoConfig.windows?
  check('the Linux/Mac download is picked by its exact name', ChronoUpdate.asset_for_here(rel)&.fetch(:name) == 'Chrono4Lich-linux.tar.gz')
end

# ---------- the installer's quoting (install.sh) ----------
if system('bash', '-c', 'true')
  helpers = File.read(File.join(ROOT, 'install.sh'))[/^sq\(\) \{.*?^desk_v\(\).*?$/m]
  check('install.sh has its quoting helpers', helpers)
  if helpers
    path = %q(/home/o'neil/$HOME/a "b"/c%d)
    out = IO.popen(['bash', '-c', "#{helpers}\nsh -c \"printf '%s' $(sq \"$1\")\"", '_', path], &:read)
    check('sq quotes a path for sh', out == path)
    out = IO.popen(['bash', '-c', "#{helpers}\ndesk_q \"$1\"", '_', %q(/p a/$H"q`b\c%d)], &:read)
    bs = '\\'
    want = %("/p a/#{bs * 2}$H#{bs * 2}"q#{bs * 2}`b#{bs * 4}c%%d")
    check('desk_q follows the desktop-entry rules', out == want)
  end
end

FileUtils.rm_rf(STATE_DIR)
puts "#{$count - $failures}/#{$count} checks passed"
exit($failures.zero? ? 0 : 1)
