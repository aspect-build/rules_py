#!/usr/bin/env python3

import requests

def pi():
    body = requests.get("https://raw.githubusercontent.com/eneko/Pi/3d647f65f5ec7a6ed9a5c2f9e61f17ce94aad0e6/one-million.txt").body
    start = body.index("3.\n")
    return body[start:].replace("\n", "")
