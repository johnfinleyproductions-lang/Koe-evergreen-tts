import unittest
from map_book_pages import page_spans
class PageMapTests(unittest.TestCase):
    def test_utf16_and_crlf_follow_original_pages(self):
        text='😀 First page.\r\nSecond page.'
        spans,confidence=page_spans(text,[(10,'First page.'),(11,'Second page.')])
        self.assertEqual(confidence,1)
        self.assertEqual([s['page'] for s in spans],[10,11])
        self.assertEqual(spans[1]['charStart'],len(text[:text.index('Second')].encode('utf-16-le'))//2)
        self.assertEqual(spans[-1]['charEnd'],len(text.encode('utf-16-le'))//2)
    def test_uncertain_page_mapping_is_marked_for_manual_reading(self):
        _,confidence=page_spans('This has completely different wording.',[(1,'The original discusses astronomy.')])
        self.assertLess(confidence,.85)
if __name__=='__main__':unittest.main()
