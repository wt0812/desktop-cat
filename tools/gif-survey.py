import os, sys
from PIL import Image, ImageSequence

D = r'C:\Users\21653\Documents\deepseek-harness\default-workspace\MikuDesktop\cat-assets\ex-F-cat-anim-pack'

def content_bbox(img):
    """The app treats white as transparent (it 'punches' white out), so the real
    cat is the non-white area, not the alpha area."""
    px = img.convert('RGB')
    w, h = px.size
    data = px.load()
    minx, miny, maxx, maxy = w, h, -1, -1
    for y in range(h):
        for x in range(w):
            r, g, b = data[x, y]
            if r < 250 or g < 250 or b < 250:
                if x < minx: minx = x
                if y < miny: miny = y
                if x > maxx: maxx = x
                if y > maxy: maxy = y
    if maxx < 0:
        return None
    return (minx, miny, maxx, maxy)

rows = []
print('%-14s %6s %8s %8s %s' % ('file', 'frames', 'box', 'delaySum', 'delays(ms)'))
print('-' * 100)
for name in sorted(os.listdir(D)):
    if not name.lower().endswith('.gif'):
        continue
    path = os.path.join(D, name)
    im = Image.open(path)
    sizes, delays = [], []
    for fr in ImageSequence.Iterator(im):
        sizes.append(fr.size)
        delays.append(fr.info.get('duration', 0))
    box = sizes[0]
    uniq = sorted(set(sizes))
    print('%-14s %6d %8s %8d %s' % (name, len(sizes), '%dx%d' % box, sum(delays), delays))
    if len(uniq) > 1:
        print('%-14s   !! frame sizes are not uniform: %s' % ('', uniq))

print()
print('=' * 100)
print('CONTENT EXTENT, measured against the clip box. This is what decides whether')
print('the cat appears to jump or change size when the clip switches.')
print('=' * 100)
print('%-14s %5s %14s %12s %10s %10s' % ('file', 'frame', 'box(w x h)', 'content(w x h)', 'leftGap', 'rightGap'))
print('-' * 100)
detail = {}
for name in ['cat_idle.gif', 'cat_a5.gif', 'cat_walk.gif', 'cat_a4.gif']:
    path = os.path.join(D, name)
    if not os.path.exists(path):
        continue
    im = Image.open(path)
    info = []
    for i, fr in enumerate(ImageSequence.Iterator(im)):
        bb = content_bbox(fr)
        if bb is None:
            continue
        w, h = fr.size
        cw, ch = bb[2] - bb[0] + 1, bb[3] - bb[1] + 1
        info.append((i, w, h, cw, ch, bb[0], w - 1 - bb[2], bb[1], h - 1 - bb[3]))
        print('%-14s %5d %14s %12s %10d %10d' % (name, i, '%dx%d' % (w, h), '%dx%d' % (cw, ch), bb[0], w - 1 - bb[2]))
    detail[name] = info

print()
print('=' * 100)
print('THE SHIFT: horizontal centre of the visible cat vs centre of the clip box')
print('=' * 100)
for name, info in detail.items():
    print()
    print(name)
    for (i, w, h, cw, ch, lg, rg, tg, bg) in info:
        content_center = lg + cw / 2.0
        box_center = w / 2.0
        off = content_center - box_center
        print('   frame %d: box %2dx%-2d  cat %2dx%-2d  centre offset %+5.1f px (art px)' % (i, w, h, cw, ch, off))
