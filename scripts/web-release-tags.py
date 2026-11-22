# Runs the web app's own release_tags() (extracted from app.py) on a release JSON; prints {"player":..., "discogs":...}.
import ast, json, re, sys
from collections.abc import Iterable
src = open('/Users/koehntopp/src/tagwright/app.py').read()
want = {'release_tags', 'clean_artist', 'uniq', 'by_role', 'COPYRIGHT_TYPES', 'DISCOGS_FIXED_KEYS', 'WRITER_ROLES'}
mod = ast.Module(body=[n for n in ast.parse(src).body if (isinstance(n, ast.FunctionDef) and n.name in want) or (isinstance(n, ast.Assign) and any(getattr(t, 'id', '') in want for t in n.targets))], type_ignores=[])
ns = {'re': re, 'Iterable': Iterable}
exec(compile(mod, 'app_extract', 'exec'), ns)
p, d = ns['release_tags'](json.load(open(sys.argv[1])))
print(json.dumps({'player': p, 'discogs': d}, sort_keys=True))
