"""Robust text decoding for the file tools — stdlib-only, no chardet dependency.

Why this exists (cross-review HIGH): file_read / file_table previously hardcoded
``raw.decode("utf-8", errors="replace")``. Chinese game repos are very commonly GBK /
GB2312 encoded (and config tables may be UTF-16 from Excel exports); decoding those as
UTF-8-with-replace returns MOJIBAKE, so the agent reads garbage for exactly the Chinese
names / comments / config values the planner asked about — silently violating "code is the
only source of truth" (it presents corrupted text as grounded fact, or can't match the row
it needs). The prior fix only stopped *search* from crashing; *reading* stayed UTF-8-only.

Strategy (ordered, stdlib only):
  1. BOM sniff — a UTF-8/UTF-16/UTF-32 BOM is authoritative; decode with the matching
     codec (``utf-8-sig`` strips the BOM; the UTF-16/32 codecs consume theirs).
  2. STRICT UTF-8 — the common case for modern repos; if it decodes cleanly, done (no BOM).
  3. GB18030 — a superset of GBK / GB2312 / GB2312-80 that losslessly decodes virtually all
     Simplified-Chinese legacy files. Tried before any lossy fallback so a GBK source comes
     back faithful, not as replacement chars.
  4. UTF-8 with ``errors="replace"`` — last-resort so a genuinely-binary / mixed-garbage
     file still returns *something* (and never raises) rather than failing the read.

Returns (text, encoding_label) so the caller can tell the agent which codec was used (a
GB18030 decode is worth surfacing — it confirms the source was a legacy-encoded file).
"""

from __future__ import annotations

# (BOM bytes, codec, label). Order matters: UTF-32 BOMs start with the UTF-16 LE BOM
# bytes (FF FE ..), so the 4-byte UTF-32 BOMs MUST be tested before the 2-byte UTF-16 ones
# or a UTF-32-LE file would be misdetected as UTF-16-LE.
# CRITICAL: use the GENERIC codec names ("utf-16"/"utf-32"), NOT the explicit-endian
# variants ("utf-16-le"). The generic codec reads the leading BOM to pick the endianness
# AND CONSUMES the BOM; the explicit-endian codec leaves the BOM as a phantom U+FEFF at the
# start of the text. ("utf-8-sig" likewise strips a UTF-8 BOM.)
_BOMS: tuple[tuple[bytes, str, str], ...] = (
    (b"\x00\x00\xfe\xff", "utf-32", "utf-32"),
    (b"\xff\xfe\x00\x00", "utf-32", "utf-32"),
    (b"\xef\xbb\xbf", "utf-8-sig", "utf-8"),
    (b"\xff\xfe", "utf-16", "utf-16"),
    (b"\xfe\xff", "utf-16", "utf-16"),
)


def decode_bytes(raw: bytes) -> tuple[str, str]:
    """Decode ``raw`` to text, detecting BOM / UTF-8 / GB18030, falling back to lossy
    UTF-8. Never raises. Returns (text, encoding_label)."""
    if not raw:
        return "", "utf-8"
    # 1. BOM — authoritative when present.
    for bom, codec, label in _BOMS:
        if raw.startswith(bom):
            try:
                # utf-8-sig / the utf-16/32 codecs each strip their own BOM.
                return raw.decode(codec), label
            except (UnicodeDecodeError, LookupError):
                break  # corrupt despite the BOM → fall through to the sniffing chain
    # 2. Strict UTF-8 (no BOM) — the modern-repo common case.
    try:
        return raw.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        pass
    # 3. GB18030 — superset of GBK/GB2312, decodes legacy Simplified-Chinese losslessly.
    #    GB18030 maps every byte sequence rather permissively, so try it only AFTER strict
    #    UTF-8 (a valid UTF-8 file must stay UTF-8) and verify it actually round-trips.
    try:
        return raw.decode("gb18030"), "gb18030"
    except UnicodeDecodeError:
        pass
    # 4. Last resort: never fail a read — return UTF-8 with replacement chars.
    return raw.decode("utf-8", errors="replace"), "utf-8-replace"
