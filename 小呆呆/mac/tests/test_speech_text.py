from speech_text import SentenceSplitter, for_speech, strip_wake_word


def test_waits_for_full_sentence():
    s = SentenceSplitter()
    assert s.feed("一天有二十四") == []
    assert s.feed("小時。還有") == ["一天有二十四小時。"]
    assert s.flush() == ["還有"]


def test_first_sentence_cut_early_at_comma():
    s = SentenceSplitter()
    assert s.feed("今天台北會下雨，記得帶傘") == ["今天台北會下雨，"]
    # 第二句以後就等句號
    assert s.feed("，出門前") == []
    assert s.feed("看一下。") == ["記得帶傘，出門前看一下。"]


def test_short_first_phrase_not_cut():
    s = SentenceSplitter()
    assert s.feed("好，") == []
    assert s.feed("我知道了。") == ["好，我知道了。"]


def test_long_sentence_without_period_cut_at_last_comma():
    s = SentenceSplitter(soft_limit=20)
    s.feed("第一句。")
    out = s.feed("這是一段很長很長的話，中間只有逗號，一直沒有句號喔")
    assert out == ["這是一段很長很長的話，中間只有逗號，"]


def test_paragraph_break_ends_sentence():
    s = SentenceSplitter()
    assert s.feed("我查一下") == []
    assert s.feed("\n") == ["我查一下"]


def test_for_speech_strips_markdown_and_links():
    assert for_speech("**重點**：看 https://example.com 這裡") == "重點：看 這裡"
    assert for_speech("[說明](http://a.b)在這") == "說明在這"
    assert for_speech("- 第一點") == "第一點"
    assert for_speech("## 標題") == "標題"


def test_for_speech_drops_unspeakable():
    assert for_speech("。") == ""
    assert for_speech("  **  ") == ""


def test_strip_wake_word_residue():
    assert strip_wake_word("呆，今天幾點？") == "今天幾點？"
    assert strip_wake_word("小呆呆，台北明天會下雨嗎") == "台北明天會下雨嗎"
    assert strip_wake_word("呆呆 一天有幾小時") == "一天有幾小時"
    assert strip_wake_word("小呆呆") == ""
    # 只去掉開頭的，句子中間的不動
    assert strip_wake_word("今天有點呆呆的") == "今天有點呆呆的"
