import os
import site
import sys
import django
import inspect

print(f'Python: {sys.executable}')
print(f'version: {sys.version}')
print(f'version info: {sys.version_info}')
print(f'cwd: {os.getcwd()}')
print(f'site-packages folder: {site.getsitepackages()}')

print('\nsys path:')
for entry in sys.path:
    print(entry)

print(f'\nEntrypoint Path: {__file__}')

print(f'\nDjango location: {django.__file__}')
print(f'Django version: {django.__version__}')

from lib import greet
print(f'\nFrom lib with wheel dependency: {greet("Matt")}')
print(f'lib filepath: {inspect.getsourcefile(greet)}')
