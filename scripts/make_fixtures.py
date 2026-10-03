#!/usr/bin/env python3
"""Original CC0 reader fixtures. Requires reportlab and Pillow."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED, ZIP_STORED
from reportlab.pdfgen.canvas import Canvas
from PIL import Image, ImageDraw
import io
root = Path(__file__).resolve().parent.parent / 'Fixtures'
root.mkdir(exist_ok=True)
paragraph = 'At dawn, Mira opened the little library beside the harbor. Every shelf held a new journey. She chose a blue book and sat by the window. The tide returned, the town woke, and the first chapter began.'
pdf = Canvas(str(root/'Harbor.pdf'), pagesize=(420, 595))
for page in range(1,4):
    pdf.setFillColorRGB(.12,.22,.28); pdf.setFont('Helvetica-Bold',24); pdf.drawString(40,535,f'The Harbor - {page}')
    pdf.setFillColorRGB(.2,.2,.2); pdf.setFont('Helvetica',12)
    for i,line in enumerate(['A small book for testing a reader.', 'Find the word harbor on every page.', '', 'The tide returned, the town woke,', 'and the first chapter began.']): pdf.drawString(40,490-i*22,line)
    pdf.setFont('Helvetica',9); pdf.drawString(40,35,f'CC0 original test fixture | Page {page}'); pdf.showPage()
pdf.save()
with ZipFile(root/'Harbor.epub','w') as z:
    z.writestr('mimetype','application/epub+zip',compress_type=ZIP_STORED)
    z.writestr('META-INF/container.xml','''<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''')
    z.writestr('OPS/package.opf','''<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:ddaa7292-598e-47b6-90f4-7d48665165ab</dc:identifier><dc:title>The Harbor</dc:title><dc:creator>Jellyfin Books Test Fixtures</dc:creator><dc:language>en</dc:language><meta property="dcterms:modified">2026-09-05T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>''')
    z.writestr('OPS/nav.xhtml','''<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="one.xhtml">The Library</a></li><li><a href="two.xhtml">The Tide</a></li></ol></nav></body></html>''')
    for file,title in [('one','The Library'),('two','The Tide')]: z.writestr(f'OPS/{file}.xhtml',f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title></head><body><h1>{title}</h1>'+''.join(f'<p>{paragraph}</p>' for _ in range(30))+'</body></html>')
with ZipFile(root/'Harbor.cbz','w',ZIP_DEFLATED) as z:
    for page in [1,2,10]:
        image=Image.new('RGB',(800,1100),(231,239,241)); draw=ImageDraw.Draw(image)
        draw.rectangle((60,70,740,1000),outline=(30,70,90),width=6)
        draw.text((100,130),f'THE HARBOR - PAGE {page}',fill=(20,50,65),font_size=40)
        draw.rectangle((100,240,700,570),fill=(117,162,181)); draw.ellipse((460,280,600,420),fill=(247,215,147))
        draw.text((100,650),'A quiet day by the water.',fill=(20,50,65),font_size=28)
        data=io.BytesIO(); image.save(data,format='PNG'); z.writestr(f'{page}.png',data.getvalue())
(root/'LICENSE.txt').write_text('These original text and image fixtures are dedicated to the public domain under CC0 1.0.\nhttps://creativecommons.org/publicdomain/zero/1.0/\n')
print('Created EPUB, PDF and CBZ fixtures')
