"""Unit tests for text_decode.decode_bytes — the robust BOM/UTF-8/GB18030 decoder
that keeps Chinese (GBK/GB2312) game-repo files from being read as mojibake."""

from __future__ import annotations

import sys
from pathlib import Path

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

from text_decode import decode_bytes  # noqa: E402


def test_plain_utf8_roundtrips():
    text, enc = decode_bytes("火球术 伤害=500".encode("utf-8"))
    assert text == "火球术 伤害=500"
    assert enc == "utf-8"


def test_ascii_is_utf8():
    text, enc = decode_bytes(b"crit_mult = 1.5")
    assert text == "crit_mult = 1.5"
    assert enc == "utf-8"


def test_gbk_chinese_decoded_faithfully_not_mojibake():
    # The core fix: a GBK/GB2312 source must come back as the real Chinese, NOT replacement
    # chars. GB18030 is a superset of GBK, so it decodes GBK losslessly.
    raw = "// 火球术 伤害=500 冷却=3秒".encode("gbk")
    text, enc = decode_bytes(raw)
    assert "火球术" in text
    assert "伤害=500" in text
    assert "�" not in text          # no replacement chars
    assert enc == "gb18030"


def test_gb2312_config_row_decoded():
    raw = "技能名,伤害,冷却\n火球术,500,3".encode("gb2312")
    text, enc = decode_bytes(raw)
    assert "火球术" in text and "技能名" in text
    assert enc == "gb18030"


def test_utf8_bom_is_stripped():
    raw = "﻿first_line=1".encode("utf-8")  # encodes a real U+FEFF BOM
    text, enc = decode_bytes(raw)
    assert text == "first_line=1"             # BOM gone — no phantom leading char
    assert enc == "utf-8"


def test_utf16_le_bom_detected():
    raw = "攻击力=100".encode("utf-16-le")
    raw = b"\xff\xfe" + raw                    # prepend the UTF-16-LE BOM
    text, enc = decode_bytes(raw)
    assert text == "攻击力=100"
    assert enc == "utf-16"


def test_utf16_be_bom_detected():
    raw = b"\xfe\xff" + "x=1".encode("utf-16-be")
    text, enc = decode_bytes(raw)
    assert text == "x=1"
    assert enc == "utf-16"


def test_utf32_bom_not_misdetected_as_utf16():
    # UTF-32-LE BOM is FF FE 00 00 — its first two bytes are the UTF-16-LE BOM, so the
    # 4-byte BOM must be tested first or this would decode wrong.
    raw = b"\xff\xfe\x00\x00" + "ok".encode("utf-32-le")
    text, enc = decode_bytes(raw)
    assert text == "ok"
    assert enc == "utf-32"


def test_empty_is_empty():
    assert decode_bytes(b"") == ("", "utf-8")


def test_pure_binary_never_raises_falls_back():
    # Random high bytes that aren't valid UTF-8 and may or may not be valid GB18030 —
    # must NEVER raise; worst case returns the lossy fallback.
    raw = bytes(range(128, 256))
    text, enc = decode_bytes(raw)
    assert isinstance(text, str)
    assert enc in ("gb18030", "utf-8-replace")


def test_valid_utf8_not_stolen_by_gb18030():
    # A valid UTF-8 file must stay utf-8 (strict UTF-8 is tried before GB18030).
    _text, enc = decode_bytes("攻击=10 防御=5 暴击率=0.3".encode("utf-8"))
    assert enc == "utf-8"


def test_latin1_not_mislabeled_as_gbk():
    # CROSS-REVIEW P1: a Latin-1 European file must NOT be decoded as plausible Chinese
    # garbage + mislabeled gb18030. The CJK-density guard rejects it → lossy UTF-8 fallback.
    raw = "für grün schön".encode("latin-1")
    text, enc = decode_bytes(raw)
    assert enc != "gb18030", f"Latin-1 wrongly labeled gb18030 as {text!r}"
    assert enc == "utf-8-replace"


def test_shift_jis_is_an_accepted_limitation():
    # KNOWN LIMITATION (documented in _looks_chinese): Shift-JIS kana mis-decode into the
    # CJK range, so a JP file is byte-indistinguishable from real Chinese and gets labeled
    # gb18030. This is out of scope for a Chinese-game-repo tool. Asserting current behavior
    # so a future encoding-detection upgrade (chardet) is a deliberate, visible change.
    raw = "こんにちは世界".encode("shift-jis")
    _text, enc = decode_bytes(raw)
    assert enc == "gb18030"  # accepted: can't byte-distinguish JP kana from GBK


def test_real_chinese_still_accepted_as_gb18030():
    # The guard must not over-reject: a genuine CJK-dense GBK file is still gb18030.
    raw = "火球术造成五百点伤害冷却三秒附带燃烧效果".encode("gbk")
    text, enc = decode_bytes(raw)
    assert enc == "gb18030"
    assert "火球术" in text


def test_mixed_chinese_with_ascii_keys_accepted():
    # A realistic config row (ASCII field names + Chinese values) is CJK-dense enough.
    raw = "skill=火球术,damage=500,desc=造成大量火焰伤害".encode("gbk")
    text, enc = decode_bytes(raw)
    assert enc == "gb18030"
    assert "火球术" in text and "造成大量火焰伤害" in text
