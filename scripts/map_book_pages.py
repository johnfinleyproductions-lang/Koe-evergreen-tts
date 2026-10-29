"""Bind prepared original-page text to the exact recorded chapter's UTF-16 offsets.
No OCR, models or audio are generated. Uncertain mappings stay manual.
"""
import argparse, difflib, json, pathlib, re

def page_spans(text, pages):
    words=list(re.finditer(r"[^\W_]+",text,re.UNICODE))
    target=[m.group().casefold() for m in words]
    original=[]; owners=[]
    for page,source in pages:
        tokens=re.findall(r"[^\W_]+",source,re.UNICODE)
        original.extend(t.casefold() for t in tokens);owners.extend([page]*len(tokens))
    if not target or not original:return [],0
    matcher=difflib.SequenceMatcher(None,original,target,autojunk=False)
    starts={};matched=0
    for a,b,size in matcher.get_matching_blocks():
        matched+=size
        for i in range(size):starts.setdefault(owners[a+i],b+i)
    confidence=matched/len(target)
    prefix=[0]
    for char in text:prefix.append(prefix[-1]+(2 if ord(char)>65535 else 1))
    anchors=sorted((index,page) for page,index in starts.items())
    spans=[]
    for i,(index,page) in enumerate(anchors):
        start=0 if i==0 else prefix[words[index].start()]
        end=prefix[words[anchors[i+1][0]].start()] if i+1<len(anchors) else prefix[-1]
        if end>start:spans.append({'page':page,'charStart':start,'charEnd':end})
    return spans,round(confidence,6)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('export');parser.add_argument('prepared_root');args=parser.parse_args()
    root=pathlib.Path(args.export);prepared=pathlib.Path(args.prepared_root)
    by_hash={}
    for name in ['acq-closer-handbook','you-were-born-rich']:
        manifest=json.loads((prepared/name/'manifest.json').read_text())
        by_hash[manifest['source']['sha256']]=manifest
    for folder in sorted(root.glob('*.koebook')):
        file=folder/'book.json';book=json.loads(file.read_text());manifest=by_hash[book['sourceSha256']]
        pages={p['pdfPage']:p['text'] for p in manifest['pages']}
        for chapter in book['chapters']:
            spans,confidence=page_spans(chapter['sourceText'],[(p,pages.get(p,'')) for p in chapter['pages']])
            chapter['pageSpans']=spans;chapter['mappingConfidence']=confidence
        file.write_text(json.dumps(book,ensure_ascii=False,separators=(',',':')))
        print(json.dumps({'book':book['title'],'chapters':len(book['chapters']),'mapped':sum(c['mappingConfidence']>=.85 for c in book['chapters']),'cached':sum(bool(c['audioFile']) for c in book['chapters'])}))

if __name__=='__main__':main()
