#!/usr/bin/env python3
"""Create a short, original EPUB for end-to-end testing; no extra packages."""
import pathlib
import sys
import zipfile

destination = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "dist/Demo.epub")
destination.parent.mkdir(parents=True, exist_ok=True)
chapters = [
    ("The Open Book", "A book begins with a quiet invitation. Open the cover, turn the page, and a new voice enters the room. This short sample demonstrates how your Mac can turn the words of an EPUB into an audiobook."),
    ("The Journey Home", "The afternoon light fell across the path as we walked home. Somewhere in the garden, a bird called twice. We stopped to listen, and for a moment the entire day felt like a story waiting to be told."),
]
with zipfile.ZipFile(destination, "w") as book:
    book.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    book.writestr("META-INF/container.xml", '<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="EPUB/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>', compress_type=zipfile.ZIP_DEFLATED)
    book.writestr("EPUB/book.opf", '''<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:72b57b16-79ae-4cf8-b419-c2e40f6d6889</dc:identifier><dc:title>A Voice for Every Page</dc:title><dc:creator>EPUB to MP3 Demo</dc:creator><dc:language>en-US</dc:language><meta property="dcterms:modified">2026-10-05T00:00:00Z</meta></metadata><manifest><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>''', compress_type=zipfile.ZIP_DEFLATED)
    for filename, (title, text) in zip(["one.xhtml", "two.xhtml"], chapters):
        book.writestr("EPUB/" + filename, f'<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title></head><body><h1>{title}</h1><p>{text}</p></body></html>', compress_type=zipfile.ZIP_DEFLATED)
    book.writestr("EPUB/nav.xhtml", '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><h1>Contents</h1><ol><li><a href="one.xhtml">The Open Book</a></li><li><a href="two.xhtml">The Journey Home</a></li></ol></nav></body></html>', compress_type=zipfile.ZIP_DEFLATED)
print(destination.resolve())
