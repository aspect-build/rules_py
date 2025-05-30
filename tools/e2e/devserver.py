#!/usr/bin/env python3

import argparse
import http.server
import os
import socketserver

PARSER = argparse.ArgumentParser(__name__)
PARSER.add_argument("--port", type=int, default=8080)
PARSER.add_argument("--dir", type=str)
PARSER.add_argument("--background", action="store_true", default=False)
PARSER.add_argument("--pidfile", type=str, default=None)

opts, args = PARSER.parse_known_args()

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=opts.dir, **kwargs)

if opts.background:
    # Fork; the child will run the server and we will exit
    status = os.fork()
    if status > 0:
        if opts.pidfile:
            with open(opts.pidfile, "w") as fp:
                fp.write("{}\n".format(status))
        exit(0)

with socketserver.TCPServer(("", opts.port), Handler) as httpd:
    print("serving at port", opts.port)
    httpd.serve_forever()
