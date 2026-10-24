# qr — a QR Code (ISO/IEC 18004) of a short text, as rows of modules, for the store sign-in page's link
# (/usr/lib/retroforge/store). Byte mode, error correction M, the smallest version that fits, and the
# mask with the lowest penalty. The algorithm follows Project Nayuki's QR Code generator (MIT).
#
#   qr.matrix("http://192.168.1.20:32010/abc")  ->  ["1111111010...", ...]  (1 = dark, no quiet zone)

# Per version 1-40 (index 0 unused), error correction M: EC codewords per block, and blocks.
ECC_PER_BLOCK = [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
                 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28]
BLOCKS = [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
          17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49]
FORMAT_M = 0  # error correction M's format bits


def raw_modules(ver):
    """Data and EC bits a version holds (all modules but the function patterns)."""
    n = (16 * ver + 128) * ver + 64
    if ver >= 2:
        align = ver // 7 + 2
        n -= (25 * align - 10) * align - 55
        if ver >= 7:
            n -= 36
    return n


def data_codewords(ver):
    return raw_modules(ver) // 8 - ECC_PER_BLOCK[ver] * BLOCKS[ver]


def gf_mul(x, y):
    z = 0
    for i in reversed(range(8)):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z


def rs_divisor(degree):
    out = [0] * (degree - 1) + [1]
    root = 1
    for _ in range(degree):
        for j in range(degree):
            out[j] = gf_mul(out[j], root)
            if j + 1 < degree:
                out[j] ^= out[j + 1]
        root = gf_mul(root, 2)
    return out


def rs_remainder(data, divisor):
    out = [0] * len(divisor)
    for b in data:
        factor = b ^ out.pop(0)
        out.append(0)
        for i, coef in enumerate(divisor):
            out[i] ^= gf_mul(coef, factor)
    return out


def codewords(text):
    """(version, data and EC codewords interleaved) for text in byte mode."""
    data = text.encode("utf-8")
    for ver in range(1, 41):
        count_bits = 8 if ver <= 9 else 16
        capacity = data_codewords(ver) * 8
        if 4 + count_bits + 8 * len(data) <= capacity:
            break
    else:
        raise ValueError("text too long for a QR code")
    bits = [0, 1, 0, 0] + [(len(data) >> i) & 1 for i in reversed(range(count_bits))]
    for b in data:
        bits += [(b >> i) & 1 for i in reversed(range(8))]
    bits += [0] * min(4, capacity - len(bits))
    bits += [0] * (-len(bits) % 8)
    words = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = 0xEC
    while len(words) < capacity // 8:
        words.append(pad)
        pad ^= 0xEC ^ 0x11
    blocks, ecc_len = BLOCKS[ver], ECC_PER_BLOCK[ver]
    raw = raw_modules(ver) // 8
    short_blocks, short_len = blocks - raw % blocks, raw // blocks
    divisor, out, k = rs_divisor(ecc_len), [], 0
    for i in range(blocks):
        dat = words[k:k + short_len - ecc_len + (0 if i < short_blocks else 1)]
        k += len(dat)
        ecc = rs_remainder(dat, divisor)
        out.append(dat + ([0] if i < short_blocks else []) + ecc)
    inter = [blk[i] for i in range(len(out[0])) for j, blk in enumerate(out)
             if i != short_len - ecc_len or j >= short_blocks]
    return ver, inter


class Grid:
    def __init__(self, ver):
        self.ver, self.size = ver, ver * 4 + 17
        self.dark = [[False] * self.size for _ in range(self.size)]
        self.fixed = [[False] * self.size for _ in range(self.size)]

    def put(self, x, y, dark):
        self.dark[y][x], self.fixed[y][x] = dark, True

    def alignment(self):
        if self.ver == 1:
            return []
        n = self.ver // 7 + 2
        step = (self.ver * 8 + n * 3 + 5) // (n * 4 - 4) * 2
        return list(reversed([self.size - 7 - i * step for i in range(n - 1)] + [6]))

    def patterns(self):
        s = self.size
        for i in range(s):
            self.put(6, i, i % 2 == 0)
            self.put(i, 6, i % 2 == 0)
        for cx, cy in ((3, 3), (s - 4, 3), (3, s - 4)):
            for dy in range(-4, 5):
                for dx in range(-4, 5):
                    if 0 <= cx + dx < s and 0 <= cy + dy < s:
                        self.put(cx + dx, cy + dy, max(abs(dx), abs(dy)) not in (2, 4))
        pos = self.alignment()
        last = len(pos) - 1
        for i, ay in enumerate(pos):
            for j, ax in enumerate(pos):
                if (i, j) in ((0, 0), (0, last), (last, 0)):
                    continue
                for dy in range(-2, 3):
                    for dx in range(-2, 3):
                        self.put(ax + dx, ay + dy, max(abs(dx), abs(dy)) != 1)
        self.format_bits(0)
        if self.ver >= 7:
            rem = self.ver
            for _ in range(12):
                rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
            bits = self.ver << 12 | rem
            for i in range(18):
                bit, a, b = (bits >> i) & 1 == 1, s - 11 + i % 3, i // 3
                self.put(a, b, bit)
                self.put(b, a, bit)

    def format_bits(self, mask):
        s, data = self.size, FORMAT_M << 3 | mask
        rem = data
        for _ in range(10):
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        bits = (data << 10 | rem) ^ 0x5412
        bit = lambda i: (bits >> i) & 1 == 1
        for i in range(6):
            self.put(8, i, bit(i))
        self.put(8, 7, bit(6))
        self.put(8, 8, bit(7))
        self.put(7, 8, bit(8))
        for i in range(9, 15):
            self.put(14 - i, 8, bit(i))
        for i in range(8):
            self.put(s - 1 - i, 8, bit(i))
        for i in range(8, 15):
            self.put(8, s - 15 + i, bit(i))
        self.put(8, s - 8, True)

    def place(self, words):
        s, i, total = self.size, 0, len(words) * 8
        right = s - 1
        while right >= 1:
            if right == 6:
                right = 5
            for vert in range(s):
                for j in range(2):
                    x = right - j
                    y = s - 1 - vert if (right + 1) & 2 == 0 else vert
                    if not self.fixed[y][x] and i < total:
                        self.dark[y][x] = (words[i >> 3] >> (7 - (i & 7))) & 1 == 1
                        i += 1
            right -= 2

    def masked(self, mask):
        test = (lambda x, y: (x + y) % 2 == 0, lambda x, y: y % 2 == 0, lambda x, y: x % 3 == 0,
                lambda x, y: (x + y) % 3 == 0, lambda x, y: (x // 3 + y // 2) % 2 == 0,
                lambda x, y: x * y % 2 + x * y % 3 == 0, lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
                lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0)[mask]
        for y in range(self.size):
            for x in range(self.size):
                if not self.fixed[y][x] and test(x, y):
                    self.dark[y][x] = not self.dark[y][x]

    def penalty(self):
        s, d, score = self.size, self.dark, 0
        lines = d + [[d[y][x] for y in range(s)] for x in range(s)]
        finder = ([1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0], [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1])
        for line in lines:
            run = 1
            for a, b in zip(line, line[1:]):
                run = run + 1 if a == b else 1
                score += 3 if run == 5 else 1 if run > 5 else 0
            bits = [int(v) for v in line]
            for i in range(s - 10):
                if bits[i:i + 11] in finder:
                    score += 40
        for y in range(s - 1):
            for x in range(s - 1):
                if d[y][x] == d[y][x + 1] == d[y + 1][x] == d[y + 1][x + 1]:
                    score += 3
        dark, total = sum(map(sum, d)), s * s
        return score + ((abs(dark * 20 - total * 10) + total - 1) // total - 1) * 10


def matrix(text):
    """The QR code of text: one string of 0 (light) and 1 (dark) per row, without a quiet zone."""
    ver, words = codewords(text)
    best = None
    for mask in range(8):
        g = Grid(ver)
        g.patterns()
        g.place(words)
        g.masked(mask)
        g.format_bits(mask)
        score = g.penalty()
        if best is None or score < best[0]:
            best = (score, g)
    return ["".join("1" if v else "0" for v in row) for row in best[1].dark]
