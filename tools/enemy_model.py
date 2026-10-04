#!/usr/bin/env python3
"""Faithful Python re-model of Planet Defender's enemy-update phase $B730-$B916
(spawn / horizontal drift / weave / project-to-sprite / tick+fire).

Mirrors the 6502 byte-for-byte so it can be validated frame-by-frame against
tools/fv_emu.py and then hand-translated to src/enemies.asm.

State is a flat 0x400 bytearray `m` addressed like the Funvision zero page +
page 3 (so m[0x02], m[0x320+X], m[0xE0+X], ... just like the RE addresses).

Data tables (raw from PlanetDefender.rom):
  weave X-step  lo $BDE2 = 00 10 10 10 00 F0 F0 F0   hi $BDEC = 00 00 00 00 00 FF FF FF
  weave Y-step  lo $BDE4 = 10 10 00 F0 F0 F0 00 10   hi $BDEE = 00 00 00 FF FF FF 00 00
  colour/group  $BE00[0/4/8] = $02 / $04 / $06
"""

WX_LO = [0x00, 0x10, 0x10, 0x10, 0x00, 0xF0, 0xF0, 0xF0]
WX_HI = [0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF]
WY_LO = [0x10, 0x10, 0x00, 0xF0, 0xF0, 0xF0, 0x00, 0x10]
WY_HI = [0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00]
BE00  = [0x02, 0x0D, 0x02, 0x03, 0x04, 0x0B, 0x03, 0x05, 0x06]

SLOTS = [0x1C, 0x18, 0x14, 0x10, 0x0C, 0x08, 0x04, 0x00]   # X iteration order


def _b(v):        # wrap to byte
    return v & 0xFF


def enemy_update(m):
    """Run one frame of $B730-$B916 in place on m (0x400 bytearray)."""
    frame_ctr = m[0x49]
    rng_lo, rng_hi = m[0x02], m[0x03]
    facing = m[0x43]

    # ---- $B730 spawn gate --------------------------------------------------
    # X = $4E (0).  Y = $52,X loaded but unused in this block.
    x = m[0x4E]
    throttle = m[0x55 + x]
    spawn_blocked = (throttle & frame_ctr) != 0
    if not spawn_blocked and (0x1A & rng_hi) != 0:
        spawn_blocked = True

    if not spawn_blocked:
        # find a free slot (state byte $0320,X == 0), X = $1C stepping -4
        free = None
        for xs in SLOTS:
            if m[0x320 + xs] == 0:
                free = xs
                break
        if free is not None:
            xs = free
            m[0x340 + xs] = _b((rng_lo & 0x1F) + 0x20)          # weave counter
            m[0x341 + xs] = rng_lo & 0x07                        # weave phase
            # $E3,X = (rng_lo >> 1) + $40 + (rng_lo & 1)   (ADC with carry)
            a = rng_lo >> 1
            c = rng_lo & 1
            a = a + 0x40 + c
            carry = a > 0xFF
            a &= 0xFF
            m[0xE3 + xs] = a                                     # enemy Y hi
            a = a & 0x07
            a = _b(a + 0x10 + (1 if carry else 0))               # carry leaks from ADC #$40
            m[0x300 + xs] = a                                    # speed  ($10-$17)
            m[0x303 + xs] = 0
            m[0x302 + xs] = 0
            if (0x80 & rng_lo) != 0:
                exhi = _b((0xC0 | rng_lo) | 0x20)                # $E0..$FF  (left, wraps in)
            else:
                exhi = _b((0x1F & rng_lo) | 0x20)               # $20..$3F  (right)
            m[0xE1 + xs] = exhi                                  # enemy X hi
            m[0x320 + xs] = 0xFF                                 # active

    # ---- $B78C drift base:  $04 = max(0, $42 - $54,X) --------------------
    x = m[0x4E]
    diff = m[0x42] - m[0x54 + x]                                 # SEC; SBC
    d04 = diff if diff >= 0 else 0
    m[0x04] = d04 & 0xFF

    # ---- horizontal homing drift  ($B79D right / $B7CA left) -------------
    # $BB73:  $06:$07 = $04 + speed      (sA, unsigned 16-bit, hi = carry)
    # $BB82:  $06:$07 = $04 - speed      (sB, signed: hi = $FF on borrow)
    # right ($B7B6):  $E0:$E1 += $06:$07
    # left  ($B7E3):  $E0:$E1 -= $06:$07
    right = (facing & 0x80) == 0
    for xs in SLOTS:
        e1 = m[0xE1 + xs]
        bit7 = (e1 & 0x80) != 0
        any_hi = (e1 & 0xE0) != 0                                # AND #$E0 ; BNE
        if right:
            if bit7:            bb73 = True                      # $B7A3 BMI
            elif any_hi:        bb73 = False                     # $B7A5 BNE -> BB82
            else:              bb73 = m[0x82 + xs] < m[0xDA]     # BCS->BB82 else BB73
        else:
            if bit7:            bb73 = False                     # $B7D0 BMI -> BB82
            elif any_hi:        bb73 = True                      # $B7D2 BNE -> BB73
            else:              bb73 = m[0x82 + xs] >= m[0xDA]    # BCC->BB82 else BB73

        spd = m[0x300 + xs]
        sA = (d04 + spd) & 0xFFFF                                # BB73
        sB = (d04 - spd) & 0xFFFF                                # BB82 (two's complement)
        delta = sA if bb73 else sB
        cur = m[0xE0 + xs] | (m[0xE1 + xs] << 8)
        cur = (cur + delta) if right else (cur - delta)
        cur &= 0xFFFF
        m[0xE0 + xs] = cur & 0xFF
        m[0xE1 + xs] = (cur >> 8) & 0xFF

    # ---- weave  ($B7F5-$B849) -------------------------------------------
    for xs in SLOTS:
        m[0x340 + xs] = _b(m[0x340 + xs] - 1)
        if m[0x340 + xs] == 0:
            m[0x340 + xs] = _b((rng_hi & 0x1F) + 0x20)
            m[0x341 + xs] = rng_lo & 0x07
        i = m[0x341 + xs] & 0xFF
        # X += BDE2:BDEC   (16-bit signed add)
        cur = m[0xE0 + xs] | (m[0xE1 + xs] << 8)
        cur = (cur + (WX_LO[i] | (WX_HI[i] << 8))) & 0xFFFF
        m[0xE0 + xs] = cur & 0xFF
        m[0xE1 + xs] = (cur >> 8) & 0xFF
        # Y += BDE4:BDEE
        ylo = m[0xE2 + xs] + WY_LO[i]
        c = 1 if ylo > 0xFF else 0
        m[0xE2 + xs] = ylo & 0xFF
        yhi = _b(m[0xE3 + xs] + WY_HI[i] + c) & 0x1F             # AND #$1F
        # reflect into band [$03,$16)
        if yhi < 0x03:
            m[0xE2 + xs] = 0x00
            yhi = 0x03
        elif yhi >= 0x16:
            m[0xE2 + xs] = 0xFF
            yhi = 0x15
        m[0xE3 + xs] = yhi

    # ---- project to sprite  ($B84B-$B8B6) -------------------------------
    m[0x6C] = _b(m[0xDB] + 0x0C)
    m[0x6D] = _b(m[0xDB] - 0x0C)
    m[0x08] = 0x01
    for xs in SLOTS:
        m[0x342 + xs] = _b(m[0x342 + xs] - 1)
        if m[0x342 + xs] == 0:
            m[0x342 + xs] = 0x17
        state = m[0x320 + xs]
        if state == 0:                                           # free
            m[0x83 + xs] = 0xE0
            continue
        if state < 0x80:                                         # spawn countdown
            continue                                             # skip projection
        if (0xE0 & m[0xE1 + xs]) != 0:                           # off visible strip
            m[0x83 + xs] = 0xE0
            continue
        # screenX = ($E0:$E1 << 3) >> 8
        v = (m[0xE0 + xs] | (m[0xE1 + xs] << 8)) << 3
        m[0x82 + xs] = (v >> 8) & 0xFF
        # group g = X mod 12  -> {0,4,8}
        g = xs % 12
        s04 = _b((g << 2) | 0x80)
        m[0x81 + xs] = _b(((m[0x342 + xs] >> 1) & 0x0C) | s04)
        m[0x80 + xs] = BE00[g]
        # screenY = ($E2:$E3 << 3) >> 8 ; hide if >= $C0
        v = (m[0xE2 + xs] | (m[0xE3 + xs] << 8)) << 3
        sy = (v >> 8) & 0xFF
        m[0x83 + xs] = 0xE0 if sy >= 0xC0 else sy

    # ---- tick + fire  ($B8BD-$B916) ------------------------------------
    # $4A toggles $0F<->$F0 each frame; $08 = $4A ; per active on-screen slot
    # LSR $08 -> C gates whether the bullet Y shows (else $E0).  Bullet attrs
    # ($A0-$A2) and the off-strip despawn run regardless of C.  Enemy bullets
    # are never advanced anywhere else (set-and-forget muzzle flash / latent
    # bug in the original) -> nothing more to do in 4d.
    m[0x4A] = _b(m[0x4A] ^ 0xFF)
    m[0x08] = m[0x4A]
    for xs in SLOTS:
        state = m[0x320 + xs]
        if state == 0:                                           # $B8CA BEQ $B90A
            m[0xA3 + xs] = 0xE0
            continue
        if state < 0x80:                                         # $B8CE DEC ; BPL
            m[0x320 + xs] = _b(state - 1)
            continue
        v = ((m[0xE2 + xs] | (m[0xE3 + xs] << 8)) << 3) >> 8     # enemy screen-Y
        sy = v & 0xFF
        if sy >= 0xC0:                                           # $B8E2 BCS $B90A
            m[0xA3 + xs] = 0xE0
            m[0x320 + xs] = 0
            continue
        c = m[0x08] & 1                                          # $B8E7 LSR $08
        m[0x08] >>= 1
        m[0xA3 + xs] = (sy >> 4) if c else 0xE0                  # $B8E4 FD47 result / $E0
        y = _b(m[0xE1 + xs] + 0x80)                              # $B8EF
        if (y & 0xE0) == 0:                                      # $B8F7 BEQ $B90A
            m[0xA3 + xs] = 0xE0
            m[0x320 + xs] = 0                                    # despawn (off left edge)
            continue
        m[0xA2 + xs] = _b((y >> 1) + 0x38)
        m[0xA0 + xs] = 0x0F
        m[0xA1 + xs] = 0xDC


if __name__ == "__main__":
    print("enemy_model: import and call enemy_update(m); validate with "
          "tools/enemy_model_check.py")
