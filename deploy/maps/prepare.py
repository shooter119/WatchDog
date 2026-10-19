#!/usr/bin/env python3
"""Build an image-pixel tile pyramid. Requires Pillow (python3-pil on Ubuntu).
Output must be a NEW directory. Install by rename on the same filesystem.
"""
import argparse
import json
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
parser.add_argument('--image', type=Path)
parser.add_argument('--name', default='正射影像')
parser.add_argument('--demo', action='store_true')
parser.add_argument('--max-pixels', type=int, default=200_000_000,
                    help='Reject larger images; use libvips for images beyond available RAM')
args = parser.parse_args()
if args.demo == bool(args.image):
    parser.error('choose exactly one of --demo or --image')
if args.output.exists():
    parser.error('output already exists; prepare a new version directory')
Image.MAX_IMAGE_PIXELS = args.max_pixels
if args.demo:
    image = Image.new('RGB', (2048, 1536), '#dde7df')
    draw = ImageDraw.Draw(image)
    for x in range(0, 2048, 128):
        draw.line((x, 0, x, 1536), fill='#b3c8b6', width=2)
    for y in range(0, 1536, 128):
        draw.line((0, y, 2048, y), fill='#b3c8b6', width=2)
    draw.rectangle((0, 650, 2048, 800), fill='#697a85')
    for index, x in enumerate(range(160, 1900, 360)):
        draw.rectangle((x, 200, x+210, 500), fill='#ac8064', outline='#664a38', width=6)
        draw.text((x+20, 240), f'DEMO {index+1}', fill='white', font=ImageFont.load_default())
    draw.text((80, 970), 'DEMO - SYNTHETIC IMAGE', fill='#9e3024', font=ImageFont.load_default())
    draw.text((80, 1060), 'NOT FOR NAVIGATION / NO GEO COORDINATES', fill='#9e3024', font=ImageFont.load_default())
else:
    with Image.open(args.image) as source:
        if source.width * source.height > args.max_pixels:
            parser.error('image exceeds --max-pixels; process with libvips or raise limit after checking RAM')
        image = source.convert('RGB')
width, height = image.size
max_zoom = max(0, math.ceil(math.log2(max(width, height) / 256)))
args.output.mkdir(parents=True)
for zoom in range(max_zoom + 1):
    factor = 2 ** (max_zoom - zoom)
    level = image.resize((math.ceil(width/factor), math.ceil(height/factor)), Image.Resampling.LANCZOS)
    for x in range(math.ceil(level.width / 256)):
        directory = args.output / 'tiles' / str(zoom) / str(x)
        directory.mkdir(parents=True)
        for y in range(math.ceil(level.height / 256)):
            tile = Image.new('RGB', (256, 256), '#dde7df')
            tile.paste(level.crop((x*256, y*256, min((x+1)*256, level.width), min((y+1)*256, level.height))))
            tile.save(directory / f'{y}.jpg', quality=88)
(args.output / 'map.json').write_text(json.dumps(dict(name='演示影像（非实景）' if args.demo else args.name,
    width=width, height=height, tileSize=256, maxZoom=max_zoom), ensure_ascii=False), encoding='utf-8')
print(f'{args.output}: {width}x{height}, zoom 0..{max_zoom}')
