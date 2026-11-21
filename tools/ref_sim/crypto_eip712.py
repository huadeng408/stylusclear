"""Pure-Python Ethereum Keccak-256, secp256k1 ECDSA sign/ecrecover, and EIP-712 Intent/Obligation hashing."""

from __future__ import annotations

import hashlib
import hmac

_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]

_ROT = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
]

MASK64 = (1 << 64) - 1


def _rol64(x: int, n: int) -> int:
    return ((x << n) | (x >> (64 - n))) & MASK64 if n else x


def _keccak_f1600(state: list[int]) -> None:
    for rnd in range(24):
        c = [state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol64(c[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                state[x + 5 * y] ^= d[x]
        b = [0] * 25
        for x in range(5):
            for y in range(5):
                b[y + 5 * ((2 * x + 3 * y) % 5)] = _rol64(state[x + 5 * y], _ROT[x][y])
        for x in range(5):
            for y in range(5):
                state[x + 5 * y] = b[x + 5 * y] ^ ((~b[((x + 1) % 5) + 5 * y] & MASK64) & b[((x + 2) % 5) + 5 * y])
        state[0] ^= _RC[rnd]


def keccak256(data: bytes) -> bytes:
    rate = 136
    state = [0] * 25
    buf = bytearray(data)
    buf.append(0x01)
    while len(buf) % rate != 0:
        buf.append(0x00)
    buf[-1] ^= 0x80
    for offset in range(0, len(buf), rate):
        block = buf[offset : offset + rate]
        for i in range(rate // 8):
            lane = int.from_bytes(block[8 * i : 8 * (i + 1)], "little")
            state[i] ^= lane
        _keccak_f1600(state)
    out = bytearray()
    for i in range(4):
        out.extend(state[i].to_bytes(8, "little"))
    return bytes(out)


SECP_P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
SECP_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
SECP_HALF_N = SECP_N // 2
SECP_GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
SECP_GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
G_POINT = (SECP_GX, SECP_GY)


def _point_add(p1: tuple[int, int] | None, p2: tuple[int, int] | None) -> tuple[int, int] | None:
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2 and (y1 + y2) % SECP_P == 0:
        return None
    if x1 == x2 and y1 == y2:
        if y1 == 0:
            return None
        lam = (3 * x1 * x1 * pow(2 * y1, SECP_P - 2, SECP_P)) % SECP_P
    else:
        lam = ((y2 - y1) * pow((x2 - x1) % SECP_P, SECP_P - 2, SECP_P)) % SECP_P
    x3 = (lam * lam - x1 - x2) % SECP_P
    y3 = (lam * (x1 - x3) - y1) % SECP_P
    return (x3, y3)


def _scalar_mul(k: int, pt: tuple[int, int] | None) -> tuple[int, int] | None:
    k = k % SECP_N
    if k == 0 or pt is None:
        return None
    res = None
    addend = pt
    while k > 0:
        if k & 1:
            res = _point_add(res, addend)
        nxt = _point_add(addend, addend)
        if nxt is None:
            break
        addend = nxt
        k >>= 1
    return res


def privkey_to_address(privkey_int: int) -> str:
    if not (0 < privkey_int < SECP_N):
        raise ValueError("Invalid secp256k1 private key")
    pt = _scalar_mul(privkey_int, G_POINT)
    assert pt is not None
    uncompressed = pt[0].to_bytes(32, "big") + pt[1].to_bytes(32, "big")
    addr_bytes = keccak256(uncompressed)[12:]
    return "0x" + addr_bytes.hex()


def _rfc6979_k(privkey_int: int, digest: bytes) -> int:
    x = privkey_int.to_bytes(32, "big")
    v = b"\x01" * 32
    k = b"\x00" * 32
    k = hmac.new(k, v + b"\x00" + x + digest, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    k = hmac.new(k, v + b"\x01" + x + digest, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    while True:
        v = hmac.new(k, v, hashlib.sha256).digest()
        cand = int.from_bytes(v, "big")
        if 1 <= cand < SECP_N:
            return cand
        k = hmac.new(k, v + b"\x00", hashlib.sha256).digest()
        v = hmac.new(k, v, hashlib.sha256).digest()


def sign_digest(privkey_int: int, digest: bytes) -> tuple[int, bytes, bytes]:
    if len(digest) != 32:
        raise ValueError("Digest must be 32 bytes")
    z = int.from_bytes(digest, "big")
    k = _rfc6979_k(privkey_int, digest)
    pt = _scalar_mul(k, G_POINT)
    assert pt is not None
    r = pt[0] % SECP_N
    rec_id = pt[1] & 1
    if pt[0] >= SECP_N:
        rec_id |= 2
    s = (pow(k, SECP_N - 2, SECP_N) * (z + r * privkey_int)) % SECP_N
    if s > SECP_HALF_N:
        s = SECP_N - s
        rec_id ^= 1
    v = 27 + (rec_id & 1)
    return v, r.to_bytes(32, "big"), s.to_bytes(32, "big")


def ecrecover(digest: bytes, v: int, r_bytes: bytes, s_bytes: bytes) -> str | None:
    if len(digest) != 32 or len(r_bytes) != 32 or len(s_bytes) != 32:
        return None
    if v not in (27, 28):
        return None
    r = int.from_bytes(r_bytes, "big")
    s = int.from_bytes(s_bytes, "big")
    if not (1 <= r < SECP_N and 1 <= s <= SECP_HALF_N):
        return None
    x = r
    if x >= SECP_P:
        return None
    rhs = (pow(x, 3, SECP_P) + 7) % SECP_P
    y = pow(rhs, (SECP_P + 1) // 4, SECP_P)
    if (y * y) % SECP_P != rhs:
        return None
    if (y & 1) != ((v - 27) & 1):
        y = SECP_P - y
    r_pt = (x, y)
    z = int.from_bytes(digest, "big")
    r_inv = pow(r, SECP_N - 2, SECP_N)
    u1 = (-z * r_inv) % SECP_N
    u2 = (s * r_inv) % SECP_N
    q = _point_add(_scalar_mul(u1, G_POINT), _scalar_mul(u2, r_pt))
    if q is None:
        return None
    pub_bytes = q[0].to_bytes(32, "big") + q[1].to_bytes(32, "big")
    return "0x" + keccak256(pub_bytes)[12:].hex()


EIP712_DOMAIN_TYPEHASH = keccak256(
    b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
)
TRADE_INTENT_TYPEHASH = keccak256(
    b"TradeIntent(address trader,uint8 baseAsset,uint8 quoteAsset,uint8 side,uint256 amountWad,uint256 limitPriceWad,uint64 maxEpoch,uint256 nonce)"
)
OBLIGATION_ATTESTATION_TYPEHASH = keccak256(
    b"ObligationAttestation(address debtor,address creditor,uint8 assetId,uint256 amountWad,uint64 maxEpoch,uint256 nonce)"
)
NAME_HASH = keccak256(b"StylusClear")
VERSION_HASH = keccak256(b"1")


def normalize_address(addr: str) -> str:
    clean = addr.lower().removeprefix("0x")
    if len(clean) != 40:
        raise ValueError(f"Invalid address: {addr}")
    int(clean, 16)
    return "0x" + clean


def _abi_word_uint(val: int) -> bytes:
    return val.to_bytes(32, "big")


def _abi_word_address(addr: str) -> bytes:
    clean = normalize_address(addr)[2:]
    return b"\x00" * 12 + bytes.fromhex(clean)


def compute_domain_separator(chain_id: int, verifying_contract: str) -> bytes:
    encoded = (
        EIP712_DOMAIN_TYPEHASH
        + NAME_HASH
        + VERSION_HASH
        + _abi_word_uint(chain_id)
        + _abi_word_address(verifying_contract)
    )
    return keccak256(encoded)


def compute_intent_digest(
    chain_id: int,
    verifying_contract: str,
    trader_addr: str,
    base_asset: int,
    quote_asset: int,
    side_code: int,
    amount_wad: int,
    limit_price_wad: int,
    max_epoch: int,
    nonce: int,
) -> bytes:
    domain_sep = compute_domain_separator(chain_id, verifying_contract)
    struct_encoded = (
        TRADE_INTENT_TYPEHASH
        + _abi_word_address(trader_addr)
        + _abi_word_uint(base_asset)
        + _abi_word_uint(quote_asset)
        + _abi_word_uint(side_code)
        + _abi_word_uint(amount_wad)
        + _abi_word_uint(limit_price_wad)
        + _abi_word_uint(max_epoch)
        + _abi_word_uint(nonce)
    )
    struct_hash = keccak256(struct_encoded)
    return keccak256(b"\x19\x01" + domain_sep + struct_hash)


def compute_obligation_digest(
    chain_id: int,
    verifying_contract: str,
    debtor_addr: str,
    creditor_addr: str,
    asset_id: int,
    amount_wad: int,
    max_epoch: int,
    nonce: int,
) -> bytes:
    domain_sep = compute_domain_separator(chain_id, verifying_contract)
    struct_encoded = (
        OBLIGATION_ATTESTATION_TYPEHASH
        + _abi_word_address(debtor_addr)
        + _abi_word_address(creditor_addr)
        + _abi_word_uint(asset_id)
        + _abi_word_uint(amount_wad)
        + _abi_word_uint(max_epoch)
        + _abi_word_uint(nonce)
    )
    struct_hash = keccak256(struct_encoded)
    return keccak256(b"\x19\x01" + domain_sep + struct_hash)


def sign_trade_intent(
    privkey_int: int,
    chain_id: int,
    verifying_contract: str,
    base_asset: int,
    quote_asset: int,
    side_code: int,
    amount_wad: int,
    limit_price_wad: int,
    max_epoch: int,
    nonce: int,
) -> dict[str, str | int]:
    trader_addr = privkey_to_address(privkey_int)
    digest = compute_intent_digest(
        chain_id,
        verifying_contract,
        trader_addr,
        base_asset,
        quote_asset,
        side_code,
        amount_wad,
        limit_price_wad,
        max_epoch,
        nonce,
    )
    v, r, s = sign_digest(privkey_int, digest)
    return {
        "mode": "EIP712",
        "v": v,
        "r": "0x" + r.hex(),
        "s": "0x" + s.hex(),
    }


def sign_obligation_attestation(
    debtor_privkey_int: int,
    chain_id: int,
    verifying_contract: str,
    creditor_addr: str,
    asset_id: int,
    amount_wad: int,
    max_epoch: int,
    nonce: int,
) -> dict[str, str | int]:
    debtor_addr = privkey_to_address(debtor_privkey_int)
    digest = compute_obligation_digest(
        chain_id,
        verifying_contract,
        debtor_addr,
        creditor_addr,
        asset_id,
        amount_wad,
        max_epoch,
        nonce,
    )
    v, r, s = sign_digest(debtor_privkey_int, digest)
    return {
        "mode": "EIP712",
        "v": v,
        "r": "0x" + r.hex(),
        "s": "0x" + s.hex(),
    }


# ---------------------------------------------------------------------------
# Pure-Python FIPS-197 AES-128-CTR & Web3 Secret Storage v3 Keystore Builder
# (Zero child processes, zero /proc/<pid>/cmdline key exposure)
# ---------------------------------------------------------------------------

_AES_SBOX = bytes.fromhex(
    "637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0"
    "b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b275"
    "09832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cf"
    "d0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2"
    "cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdb"
    "e0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08"
    "ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9e"
    "e1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16"
)
_RCON = (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36)


def _xtime(a: int) -> int:
    return ((a << 1) ^ 0x1B) & 0xFF if (a & 0x80) else (a << 1)


def _aes128_expand_key(key16: bytes) -> list[list[int]]:
    if len(key16) != 16:
        raise ValueError("AES-128 key must be 16 bytes")
    w = [list(key16[i : i + 4]) for i in range(0, 16, 4)]
    for i in range(4, 44):
        temp = list(w[i - 1])
        if i % 4 == 0:
            temp = [_AES_SBOX[temp[1]] ^ _RCON[(i // 4) - 1], _AES_SBOX[temp[2]], _AES_SBOX[temp[3]], _AES_SBOX[temp[0]]]
        w.append([w[i - 4][j] ^ temp[j] for j in range(4)])
    return [[w[r * 4 + c][b] for c in range(4) for b in range(4)] for r in range(11)]


def _aes128_encrypt_block(block16: bytes, round_keys: list[list[int]]) -> bytes:
    s = [block16[i] ^ round_keys[0][i] for i in range(16)]
    for rnd in range(1, 10):
        s = [_AES_SBOX[b] for b in s]
        s = [
            s[0], s[5], s[10], s[15],
            s[4], s[9], s[14], s[3],
            s[8], s[13], s[2], s[7],
            s[12], s[1], s[6], s[11],
        ]
        for c in range(0, 16, 4):
            a0, a1, a2, a3 = s[c], s[c + 1], s[c + 2], s[c + 3]
            t = a0 ^ a1 ^ a2 ^ a3
            s[c] ^= t ^ _xtime(a0 ^ a1)
            s[c + 1] ^= t ^ _xtime(a1 ^ a2)
            s[c + 2] ^= t ^ _xtime(a2 ^ a3)
            s[c + 3] ^= t ^ _xtime(a3 ^ a0)
        rk = round_keys[rnd]
        s = [s[i] ^ rk[i] for i in range(16)]
    s = [_AES_SBOX[b] for b in s]
    s = [
        s[0], s[5], s[10], s[15],
        s[4], s[9], s[14], s[3],
        s[8], s[13], s[2], s[7],
        s[12], s[1], s[6], s[11],
    ]
    rk10 = round_keys[10]
    return bytes(s[i] ^ rk10[i] for i in range(16))


def encrypt_aes128_ctr(key16: bytes, iv16: bytes, data: bytes) -> bytes:
    if len(iv16) != 16:
        raise ValueError("AES-128-CTR IV must be 16 bytes")
    rks = _aes128_expand_key(key16)
    ctr = int.from_bytes(iv16, "big")
    out = bytearray()
    for off in range(0, len(data), 16):
        ks = _aes128_encrypt_block(((ctr + (off // 16)) & ((1 << 128) - 1)).to_bytes(16, "big"), rks)
        chunk = data[off : off + 16]
        out.extend(b ^ k for b, k in zip(chunk, ks[: len(chunk)], strict=True))
    return bytes(out)


def build_web3_keystore_v3(privkey_bytes: bytes, password: str, salt32: bytes, iv16: bytes, key_uuid: str) -> dict[str, object]:
    import hashlib

    if len(privkey_bytes) != 32:
        raise ValueError("Private key must be 32 bytes")
    dk = hashlib.scrypt(password.encode("utf-8"), salt=salt32, n=4096, r=8, p=1, maxmem=64 * 1024 * 1024, dklen=32)
    ct = encrypt_aes128_ctr(dk[:16], iv16, privkey_bytes)
    mac = keccak256(dk[16:32] + ct).hex()
    addr = privkey_to_address(int.from_bytes(privkey_bytes, "big"))[2:].lower()
    return {
        "version": 3,
        "id": key_uuid,
        "address": addr,
        "crypto": {
            "cipher": "aes-128-ctr",
            "cipherparams": {"iv": iv16.hex()},
            "ciphertext": ct.hex(),
            "kdf": "scrypt",
            "kdfparams": {"dklen": 32, "n": 4096, "p": 1, "r": 8, "salt": salt32.hex()},
            "mac": mac,
        },
    }
