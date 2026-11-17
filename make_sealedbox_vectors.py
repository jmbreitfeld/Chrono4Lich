# Makes test/sealedbox_vectors.json with the real libsodium (PyNaCl), for test_sealedbox.rb.
#   pip install pynacl && python3 test/make_sealedbox_vectors.py
# Sealed boxes use a random one-time key, so each vector fixes that key ("ephemeral_secret").
# libsodium's own crypto_box_seal is checked to open what Chrono's format produces.
import json, os, hashlib
from nacl import bindings as b
from nacl.public import PrivateKey, SealedBox

vectors = []
for size in [0, 1, 15, 16, 31, 32, 63, 64, 100, 127, 128, 129, 255, 1000]:
    recipient = PrivateKey.generate()
    pk = bytes(recipient.public_key)
    esk = os.urandom(32)
    epk = b.crypto_scalarmult_base(esk)
    nonce = hashlib.blake2b(epk + pk, digest_size=24).digest()
    msg = os.urandom(size)
    sealed = epk + b.crypto_box(msg, nonce, pk, esk)
    assert SealedBox(recipient).decrypt(sealed) == msg  # libsodium opens it
    vectors.append({"public_key": pk.hex(), "ephemeral_secret": esk.hex(), "message": msg.hex(), "sealed": sealed.hex()})
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sealedbox_vectors.json")
with open(path, "w") as f:
    json.dump({"made_with": "PyNaCl (libsodium)", "vectors": vectors}, f, indent=1)
print(f"wrote {len(vectors)} vectors to {path}")
