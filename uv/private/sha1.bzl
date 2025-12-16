"""
Sha1sum implemented in pure Starlark for portability.

Certainly not for efficiency good lord.
"""

load("@bazel_lib//lib:strings.bzl", "ord")

def rotl32(x, n):
    """Rot[ate] L[eft] for 32bi wide.

    Args:
       x (int): The value to rotate
       n (int): The number of bits by which to rotate

    Returns:
       The rotated value
    """
    return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF

# buildifier: disable=uninitialized
def sha1(input):
    """sha1sum.

    Args:
        input: An iterator of characters (e.g., a string).

    Returns:
        a 40-character hexadecimal string representing the SHA-1 hash.
    """

    # --- SHA-1 Constants and Initial Hash Values ---
    h0 = 0x67452301
    h1 = 0xEFCDAB89
    h2 = 0x98BADCFE
    h3 = 0x10325476
    h4 = 0xC3D2E1F0

    k = [
        0x5A827999,  # 0 <= t <= 19
        0x6ED9EBA1,  # 20 <= t <= 39
        0x8F1BBCDC,  # 40 <= t <= 59
        0xCA62C1D6,  # 60 <= t <= 79
    ]

    message_bytes_list = []
    for char in input.elems():
        message_bytes_list.append(ord(char))

    original_length_in_bits = len(message_bytes_list) * 8

    message_bytes_list.append(0x80)

    bits_after_one = len(message_bytes_list) * 8

    remaining_bits_in_block = 512 - (bits_after_one % 512)

    if remaining_bits_in_block < 64:
        num_zero_bits = remaining_bits_in_block + 448
    else:
        num_zero_bits = remaining_bits_in_block - 64

    num_zero_bytes = num_zero_bits // 8

    for _ in range(num_zero_bytes):
        message_bytes_list.append(0x00)

    message_bytes_list.append((original_length_in_bits >> 56) & 0xFF)
    message_bytes_list.append((original_length_in_bits >> 48) & 0xFF)
    message_bytes_list.append((original_length_in_bits >> 40) & 0xFF)
    message_bytes_list.append((original_length_in_bits >> 32) & 0xFF)
    message_bytes_list.append((original_length_in_bits >> 24) & 0xFF)
    message_bytes_list.append((original_length_in_bits >> 16) & 0xFF)
    message_bytes_list.append((original_length_in_bits >> 8) & 0xFF)
    message_bytes_list.append(original_length_in_bits & 0xFF)

    num_blocks = len(message_bytes_list) // 64

    for i in range(num_blocks):
        block = message_bytes_list[i * 64:(i + 1) * 64]

        w = [0] * 80

        for t in range(16):
            word_val = (block[t * 4] << 24) | \
                       (block[t * 4 + 1] << 16) | \
                       (block[t * 4 + 2] << 8) | \
                       (block[t * 4 + 3])
            w[t] = word_val

        for t in range(16, 80):
            w[t] = rotl32(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1)

        a = h0
        b = h1
        c = h2
        d = h3
        e = h4

        for t in range(80):
            if 0 <= t and t <= 19:
                f = (b & c) | ((~b) & d)
                kt = k[0]
            elif 20 <= t and t <= 39:
                f = b ^ c ^ d
                kt = k[1]
            elif 40 <= t and t <= 59:
                f = (b & c) | (b & d) | (c & d)
                kt = k[2]
            elif 60 <= t and t <= 79:
                f = b ^ c ^ d
                kt = k[3]
            else:
                # FIXME: Error?
                pass

            temp = (rotl32(a, 5) + f + e + kt + w[t]) & 0xFFFFFFFF

            e = d
            d = c
            c = rotl32(b, 30)
            b = a
            a = temp

        h0 = (h0 + a) & 0xFFFFFFFF
        h1 = (h1 + b) & 0xFFFFFFFF
        h2 = (h2 + c) & 0xFFFFFFFF
        h3 = (h3 + d) & 0xFFFFFFFF
        h4 = (h4 + e) & 0xFFFFFFFF

    def hex(word):
        # Converts a 32-bit word (0 to 0xFFFFFFFF) to 8 hex characters
        hex_chars = "0123456789abcdef"
        result = [""] * 8
        for i in range(8):
            nibble = (word >> (28 - i * 4)) & 0xF
            result[i] = hex_chars[nibble]
        return "".join(result)

    final_hash = (hex(h0) +
                  hex(h1) +
                  hex(h2) +
                  hex(h3) +
                  hex(h4))

    return final_hash
