"""The web app as the reference for the macOS port's parity tests (WebParityTests.swift).

Reads {"fn": name, "cases": [...]} as JSON on stdin and prints the web app's answer for every case as a JSON list.
pipeline/ and library/ are imported; functions that live in app.py are extracted with ast (importing app.py would
start the web app). Run with the web app's interpreter: ../tagwright/.venv/bin/python scripts/web-oracle.py
"""

import ast
import json
import re
import sys
import tempfile
from collections.abc import Iterable
from pathlib import Path

WEB = Path(__file__).resolve().parents[2] / 'tagwright'
sys.path.insert(0, str(WEB))

from pipeline import credits, fixtags, lyrics, naming  # noqa: E402
from pipeline.positions import Positions  # noqa: E402
from pipeline.tagio import tag  # noqa: E402
from library import template  # noqa: E402


def from_app(*names: str, **extra: object) -> dict:
	"""Functions and constants of app.py by name, executed on their own."""
	tree = ast.parse((WEB / 'app.py').read_text())
	keep = [
		n
		for n in tree.body
		if (isinstance(n, ast.FunctionDef) and n.name in names)
		or (isinstance(n, ast.Assign) and any(getattr(t, 'id', '') in names for t in n.targets))
	]
	ns: dict = {'re': re, 'Iterable': Iterable, 'tag': tag, **extra}
	exec(compile(ast.Module(body=keep, type_ignores=[]), 'app.py', 'exec'), ns)
	return ns


def upper(t: dict) -> dict:
	return {k.upper(): v for k, v in t.items()}


def release_tags(c):
	ns = from_app('release_tags', 'COPYRIGHT_TYPES', 'DISCOGS_FIXED_KEYS', clean_artist=credits.clean_artist, uniq=credits.uniq)
	p, d = ns['release_tags'](json.loads(Path(c).read_text()))
	return {'player': p, 'discogs': d}


def track_tags(c):
	"""ARTIST and the credit tags of every track of a release file, in flat_tracks order (ADR 0100)."""
	r = json.loads(Path(c).read_text())
	return [credits.track_tags(r, i) for i in range(len(credits.flat_tracks(r)))]


def positions(c):
	"""Disc and track of a run of positions; an item starting with '#' is a heading (ADR 0101)."""
	p, out = Positions(), []
	for item in c:
		if item.startswith('#'):
			p.heading(item[1:])
		else:
			out.append(list(p.place(item) or []))
	return out


def album_issues(c):
	ns = from_app('album_issues', 'count_text', 'cover_note', 'ALBUM_LEVEL', 'MISSING_TEXT', 'CATALOG_KEYS', MIN_COVER=c['min_cover'])
	out = {'discogs': tag(upper(c['tags'][0]), 'DISCOGS_RELEASE_ID'), 'cover': c.get('cover')}
	return ns['album_issues'](out, [upper(t) for t in c['tags']], c['small_cover'])


def lyric_kind(c):
	ns = from_app('lyric_kind', 'SYNCED_RE', 'INSTRUMENTAL_RE')
	return ns['lyric_kind'](upper(c))


def template_target(c):
	try:
		t = template.target(template.default(), c['tags'], c.get('suffix', '.flac'))
		return {'album_dir': list(t.album_dir), 'disc_dir': t.disc_dir, 'filename': t.filename}
	except Exception as e:  # MissingTag, ValueError: the case says which
		return {'error': type(e).__name__}


def lyrics_fetch(c):
	"""fetch_one on a minimal FLAC with the case's tags; the lookup answers from c['answers'] in call order
	(a dict = found, {} = not found, null = failed)."""
	from mutagen.flac import FLAC

	with tempfile.TemporaryDirectory() as d:
		p = Path(d) / 'track.flac'
		rate, samples = 44100, int(c['length'] * 44100)
		si = bytes(4) + bytes([0, 0, 0, 0, 0, 0])
		packed = (rate << 44) | (1 << 41) | (15 << 36) | samples
		si += packed.to_bytes(8, 'big') + bytes(16)
		p.write_bytes(b'fLaC' + bytes([0x80, 0, 0, 34]) + si + bytes(100))
		f = FLAC(p)
		for k, v in c['tags'].items():
			f[k] = v
		f.save()
		answers = list(c['answers'])
		calls: list = []

		def lookup(params):
			calls.append(params)
			return answers.pop(0) if answers else {}

		r = lyrics.fetch_one(p, lookup)
		return {'lyrics': r.lyrics, 'kind': r.kind, 'action': r.action, 'calls': len(calls)}


FNS = {
	'bliss_name': lambda c: naming.bliss_name(upper(c)),
	'bliss_album': lambda c: naming.bliss_album(upper(c)),
	'clean': naming.clean,
	'version_string': lambda c: fixtags.version_string(*c),
	'release_tags': release_tags,
	'track_tags': track_tags,
	'positions': positions,
	'album_issues': album_issues,
	'lyric_kind': lyric_kind,
	'template_target': template_target,
	'lyrics_fetch': lyrics_fetch,
}

req = json.load(sys.stdin)
print(json.dumps([FNS[req['fn']](c) for c in req['cases']], ensure_ascii=False))
