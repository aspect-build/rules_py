#!/usr/bin/env python3

# Explicit dep
import requests
print(requests.__file__)

# Implied dep of urllib
import urllib3
print(urllib3.__file__)

# Implied dep via urllib3[brotli]
import brotli
print(brotli.__file__)
