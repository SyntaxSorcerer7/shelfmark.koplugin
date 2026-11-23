"""Shelfmark with deterministic metadata and source adapters for integration tests.

The Shelfmark Flask routes, queue, post-processing and local-download route are real.
Only the external metadata provider and book source are replaced with fixtures.
"""
import os
import zipfile
import sqlite3
import uuid
from werkzeug.security import generate_password_hash
from pathlib import Path

os.environ.update(CONFIG_DIR='/tmp/shelfmark-e2e-auth/config', INGEST_DIR='/tmp/shelfmark-e2e-auth/books', TMP_DIR='/tmp/shelfmark-e2e-auth/tmp', AUTH_METHOD='cwa', CWA_DB_PATH='/tmp/shelfmark-e2e-auth/cwa.db', OPENLIBRARY_ENABLED='true', METADATA_PROVIDER='openlibrary', BOOK_LANGUAGE='de', HARDCOVER_ENABLED='false')
for folder in ('config', 'books', 'tmp'):
    Path('/tmp/shelfmark-e2e-auth', folder).mkdir(parents=True, exist_ok=True)

with sqlite3.connect(os.environ['CWA_DB_PATH']) as db:
    db.execute('CREATE TABLE IF NOT EXISTS user (name TEXT, password TEXT, role INTEGER, email TEXT)')
    db.execute('DELETE FROM user')
    db.execute('INSERT INTO user VALUES (?, ?, ?, ?)', ('fixture-user', generate_password_hash('fixture-password'), 1, 'fixture@example.test'))

import shelfmark.metadata_providers as metadata
from shelfmark.release_sources import Release, ReleaseSource, DownloadHandler, register_source, register_handler

# Deterministic external adapters. Shelfmark's HTTP routes, auth, metadata
# registry, queue and post-processing are unchanged.
metadata._PROVIDERS.clear()
book = metadata.BookMetadata(provider='openlibrary', provider_id='fixture-1', title='Das Testbuch', authors=['Test Autor'], description='Eine Geschichte für den Shelfmark-Integrationstest.', cover_url='/api/e2e-cover', language='de')

@metadata.register_provider('openlibrary')
class Provider(metadata.MetadataProvider):
    name = 'openlibrary'
    display_name = 'Test Library'
    requires_auth = False
    search_fields = (
        metadata.TextSearchField(key='author', label='Author'),
        metadata.TextSearchField(key='title', label='Title'),
    )
    def is_available(self): return True
    def search(self, options):
        query = options.query or options.fields.get('author') or options.fields.get('title') or ''
        return [book] if 'test' in query.lower() else []
    def get_book(self, book_id): return book if book_id == book.provider_id else None
    def search_by_isbn(self, isbn): return None

@metadata.register_provider('disabled_fixture')
class DisabledProvider(Provider):
    name = 'disabled_fixture'
    display_name = 'Disabled Library'

# Prevent a test request from reaching a real download source.
import shelfmark.release_sources as sources
sources._SOURCES.clear()

@register_source('e2e')
class FixtureSource(ReleaseSource):
    name = 'e2e'
    display_name = 'Testquelle'
    def is_available(self): return True
    def search(self, *args, **kwargs):
        return [Release(source='e2e', source_id='fixture-' + uuid.uuid4().hex, title='Das Testbuch', format='epub', language='de', content_type='ebook')]

@register_handler('e2e')
class FixtureHandler(DownloadHandler):
    def cancel(self, task_id): return True
    def download(self, task, cancel_flag, progress_callback, status_callback):
        path = Path(os.environ['TMP_DIR']) / 'fixture.epub'
        with zipfile.ZipFile(path, 'w') as z:
            z.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
            z.writestr('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
            z.writestr('content.opf', '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Das Testbuch</dc:title><dc:language>de</dc:language><dc:identifier id="id">test</dc:identifier></metadata><manifest><item id="text" href="text.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="text"/></spine></package>')
            z.writestr('text.xhtml', '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Test</title></head><body><p>Ende-zu-Ende-Test bestanden.</p></body></html>')
        return str(path)

from shelfmark.main import app, socketio

@app.get('/opds')
def opds_root():
    from flask import Response
    xml = '''<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><id>test</id><title>Testkatalog</title><link rel="search" type="application/atom+xml" href="/opds/search?q={searchTerms}"/></feed>'''
    return Response(xml, mimetype='application/atom+xml')

@app.get('/opds/search')
def opds_search():
    from flask import Response, request
    query = request.args.get('q', '')
    if query == 'Das Testbuch':
        entry = '''<entry><title>Das Testbuch</title><id>urn:test:book</id><author><name>Test Autor</name></author><link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/test.epub"/></entry>'''
    else:
        entry = ''
    return Response('<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><id>search</id><title>Suchergebnisse</title>' + entry + '</feed>', mimetype='application/atom+xml')

@app.get('/test.epub')
def test_epub():
    from flask import send_file
    files = list(Path('/tmp/shelfmark-e2e-auth/books').rglob('*.epub'))
    assert files, 'Shelfmark has not completed the test book'
    return send_file(files[0], mimetype='application/epub+zip')

@app.get('/api/e2e-cover')
def cover():
    import struct, zlib
    from flask import Response
    width, height = 180, 260
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            shade = 30 if 12 < x < 168 and 12 < y < 248 else 230
            if 55 < y < 75 or 185 < y < 195: shade = 220
            row.extend([shade, shade, shade])
        rows.append(row)
    image = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b'')
    return Response(image, mimetype='image/png')

socketio.run(app, host='0.0.0.0', port=8084, allow_unsafe_werkzeug=True)
