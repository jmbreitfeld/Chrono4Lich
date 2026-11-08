# chrono_sealedbox.rb - libsodium's crypto_box_seal ("sealed box") in plain Ruby.
#
# GitHub requires repository secrets to be encrypted this way with the repository's public key
# (https://docs.github.com/en/rest/guides/encrypting-secrets-for-the-rest-api). Ruby has no
# built-in libsodium, so this implements exactly what crypto_box_seal does, from the published
# algorithms, rather than making every user install a library:
#   X25519 (RFC 7748), XSalsa20 + Poly1305 (NaCl crypto_box), BLAKE2b (RFC 7693).
# Chrono's tests check it against the real libsodium (PyNaCl) on random inputs.
#
# Only encryption is needed: GitHub decrypts with its private key.

require 'securerandom'

module SealedBox
  module_function

  MASK32 = 0xffffffff
  MASK64 = 0xffffffffffffffff

  # ---------- X25519 (RFC 7748) ----------

  P25519 = 2**255 - 19
  A24 = 121_665

  def x25519(scalar32, u32)
    k = scalar32.bytes
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    k = le_int(k)
    u = le_int(u32.bytes) & ((1 << 255) - 1)
    x1 = u
    x2 = 1
    z2 = 0
    x3 = u
    z3 = 1
    swap = 0
    254.downto(0) do |t|
      kt = (k >> t) & 1
      swap ^= kt
      x2, x3 = x3, x2 if swap == 1
      z2, z3 = z3, z2 if swap == 1
      swap = kt
      a = (x2 + z2) % P25519
      aa = a * a % P25519
      b = (x2 - z2) % P25519
      bb = b * b % P25519
      e = (aa - bb) % P25519
      c = (x3 + z3) % P25519
      d = (x3 - z3) % P25519
      da = d * a % P25519
      cb = c * b % P25519
      x3 = (da + cb)**2 % P25519
      z3 = x1 * ((da - cb)**2 % P25519) % P25519
      x2 = aa * bb % P25519
      z2 = e * ((aa + A24 * e) % P25519) % P25519
    end
    x2, x3 = x3, x2 if swap == 1
    z2, z3 = z3, z2 if swap == 1
    int_le(x2 * z2.pow(P25519 - 2, P25519) % P25519, 32)
  end

  def x25519_base(scalar32)
    x25519(scalar32, int_le(9, 32))
  end

  # ---------- Salsa20 / HSalsa20 / XSalsa20 ----------

  SIGMA = 'expand 32-byte k'.unpack('V4')

  def rotl(v, c) = ((v << c) | (v >> (32 - c))) & MASK32

  def salsa_rounds(x)
    10.times do
      [[0, 4, 8, 12], [5, 9, 13, 1], [10, 14, 2, 6], [15, 3, 7, 11],
       [0, 1, 2, 3], [5, 6, 7, 4], [10, 11, 8, 9], [15, 12, 13, 14]].each do |a, b, c, d|
        x[b] ^= rotl((x[a] + x[d]) & MASK32, 7)
        x[c] ^= rotl((x[b] + x[a]) & MASK32, 9)
        x[d] ^= rotl((x[c] + x[b]) & MASK32, 13)
        x[a] ^= rotl((x[d] + x[c]) & MASK32, 18)
      end
    end
    x
  end

  def salsa_input(key32, n16)
    k = key32.unpack('V8')
    n = n16.unpack('V4')
    [SIGMA[0], k[0], k[1], k[2], k[3], SIGMA[1], n[0], n[1], n[2], n[3], SIGMA[2], k[4], k[5], k[6], k[7], SIGMA[3]]
  end

  def hsalsa20(key32, nonce16)
    x = salsa_rounds(salsa_input(key32, nonce16))
    [x[0], x[5], x[10], x[15], x[6], x[7], x[8], x[9]].pack('V8')
  end

  def salsa20_block(key32, nonce8, counter)
    input = salsa_input(key32, nonce8 + [counter & MASK64].pack('Q<'))
    x = salsa_rounds(input.dup)
    x.each_index.map { |i| (x[i] + input[i]) & MASK32 }.pack('V16')
  end

  def xsalsa20_stream(key32, nonce24, length)
    sub = hsalsa20(key32, nonce24[0, 16])
    out = +''.b
    counter = 0
    while out.bytesize < length
      out << salsa20_block(sub, nonce24[16, 8], counter)
      counter += 1
    end
    out[0, length]
  end

  # ---------- Poly1305 ----------

  def poly1305(msg, key32)
    r = le_int(key32[0, 16].bytes) & 0x0ffffffc0ffffffc0ffffffc0fffffff
    s = le_int(key32[16, 16].bytes)
    p = 2**130 - 5
    acc = 0
    msg.bytes.each_slice(16) do |chunk|
      n = le_int(chunk) + (1 << (8 * chunk.size))
      acc = (acc + n) * r % p
    end
    int_le((acc + s) & ((1 << 128) - 1), 16)
  end

  # ---------- crypto_box (XSalsa20-Poly1305 over an X25519 shared key) ----------

  def box(message, nonce24, public32, secret32)
    shared = hsalsa20(x25519(secret32, public32), "\0".b * 16)
    stream = xsalsa20_stream(shared, nonce24, 32 + message.bytesize)
    cipher = xor(message, stream[32..])
    poly1305(cipher, stream[0, 32]) + cipher
  end

  # ---------- BLAKE2b (RFC 7693), unkeyed, any output length 1..64 ----------

  IV = [0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179].freeze
  SIGMA_B = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4], [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13], [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11], [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5], [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
  ].freeze

  def rotr64(v, c) = ((v >> c) | (v << (64 - c))) & MASK64

  def blake2b(data, outlen)
    h = IV.dup
    h[0] ^= 0x01010000 ^ outlen
    data = data.b
    blocks = data.empty? ? [''.b] : data.scan(/.{1,128}/mn)
    total = 0
    blocks.each_with_index do |block, i|
      total += block.bytesize
      last = i == blocks.size - 1
      m = (block + ("\0".b * (128 - block.bytesize))).unpack('Q<16')
      v = h + IV
      v[12] ^= total & MASK64
      v[13] ^= (total >> 64) & MASK64
      v[14] ^= MASK64 if last
      12.times do |round|
        s = SIGMA_B[round % 10]
        [[0, 4, 8, 12, 0], [1, 5, 9, 13, 2], [2, 6, 10, 14, 4], [3, 7, 11, 15, 6],
         [0, 5, 10, 15, 8], [1, 6, 11, 12, 10], [2, 7, 8, 13, 12], [3, 4, 9, 14, 14]].each do |a, b, c, d, j|
          v[a] = (v[a] + v[b] + m[s[j]]) & MASK64
          v[d] = rotr64(v[d] ^ v[a], 32)
          v[c] = (v[c] + v[d]) & MASK64
          v[b] = rotr64(v[b] ^ v[c], 24)
          v[a] = (v[a] + v[b] + m[s[j + 1]]) & MASK64
          v[d] = rotr64(v[d] ^ v[a], 16)
          v[c] = (v[c] + v[d]) & MASK64
          v[b] = rotr64(v[b] ^ v[c], 63)
        end
      end
      8.times { |k| h[k] ^= v[k] ^ v[k + 8] }
    end
    h.pack('Q<8')[0, outlen]
  end

  # ---------- crypto_box_seal ----------

  # Encrypts message for the holder of public32's private key. Output: ephemeral public key,
  # then the box. Same format libsodium's crypto_box_seal produces.
  def seal(message, public32, ephemeral_secret = SecureRandom.random_bytes(32))
    public32 = public32.b
    raise ArgumentError, 'public key must be 32 bytes' unless public32.bytesize == 32
    epk = x25519_base(ephemeral_secret)
    nonce = blake2b(epk + public32, 24)
    epk + box(message.b, nonce, public32, ephemeral_secret)
  end

  # ---------- helpers ----------

  def le_int(bytes) = bytes.each_with_index.sum { |b, i| b << (8 * i) }
  def int_le(n, len) = Array.new(len) { |i| (n >> (8 * i)) & 0xff }.pack('C*')
  def xor(a, b) = a.bytes.zip(b.bytes).map { |x, y| x ^ y }.pack('C*')
end
