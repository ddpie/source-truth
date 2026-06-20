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
    #    GB18030 is EXTREMELY permissive: it decodes almost any byte sequence without
    #    raising, so a non-Chinese legacy file (Latin-1 European é/ü, Shift-JIS Japanese,
    #    a binary-ish blob) would "succeed" into PLAUSIBLE-LOOKING Chinese garbage and get
    #    mislabeled "gb18030" — worse than a visible replacement char, because it reads as
    #    a confident faithful decode (cross-review P1). So accept gb18030 ONLY when the
    #    result is actually Chinese-DOMINANT: a genuine GBK/GB2312 source is full of CJK
    #    code points, whereas mis-decoded Latin-1/Shift-JIS yields a scatter of random CJK
    #    among latin/punctuation. Require a meaningful CJK fraction before trusting it.
    try:
        candidate = raw.decode("gb18030")
        if _looks_chinese(candidate):
            return candidate, "gb18030"
    except UnicodeDecodeError:
        pass
    # 4. Last resort: never fail a read — return UTF-8 with replacement chars. Reached when
    #    the bytes are neither valid UTF-8 nor convincingly-Chinese GB18030 (binary, or a
    #    non-Chinese legacy encoding we don't claim to handle — better a visible � than
    #    confident garbage mislabeled as a real encoding).
    return raw.decode("utf-8", errors="replace"), "utf-8-replace"


# CJK Unified Ideographs (the bulk of Chinese text) + common fullwidth/CJK-symbol ranges.
def _looks_chinese(text: str) -> bool:
    """True when ``text`` is Chinese-DOMINANT enough to trust a GB18030 decode over the
    lossy UTF-8 fallback. Heuristic: CJK ideographs must be a meaningful fraction of the
    WHOLE text (not just of the non-ASCII subset). Rationale:
      - A Latin-1 European file (`für grün schön`) is mostly ASCII with a FEW accented
        bytes; each accent mis-decodes to one CJK char, so "CJK / non-ASCII" would be 100%
        and wrongly pass — but "CJK / total" is low (~20%), so a total-fraction gate
        rejects it → falls through to the visible-� UTF-8 fallback (better than confident
        garbage mislabeled gb18030).
      - A real GBK/GB2312 config or source is CJK-DENSE over the whole content (a name
        column, a comment, a description) → easily clears the gate.
    DISCRIMINATOR: real Chinese comes in RUNS of consecutive ideographs (词语/句子 — e.g.
    `火球术`, `造成伤害`), whereas a Latin-1 European mis-decode produces only ISOLATED CJK
    chars (each accented byte → one lone ideograph wedged between ASCII letters/spaces). So
    we require a run of >= MIN_RUN consecutive CJK somewhere — `火球术` (3-run) in ASCII code
    passes; `f黵 gr黱 sch鰊` (all 1-runs) fails → falls to the visible-� UTF-8 fallback.
    KNOWN LIMITATION (accepted): a Shift-JIS / EUC-JP *Japanese* file's kana also mis-decode
    into the CJK range AND form runs, so this gate cannot byte-distinguish it from real
    Chinese and will label it gb18030. Out of scope for a Chinese-game-repo tool; the
    gb18030 label at least flags "legacy decode, verify" rather than silent UTF-8."""
    if not text:
        return False
    MIN_RUN = 2  # two consecutive ideographs = a real Chinese word, not an accent scatter
    run = 0
    for c in text:
        if "一" <= c <= "鿿" or "㐀" <= c <= "䶿":
            run += 1
            if run >= MIN_RUN:
                return True
        else:
            run = 0
    return False
