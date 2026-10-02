#!/usr/bin/env python3
"""Smoke test that the multi-project @pypi_multi hub resolves to a working cowsay."""

import cowsay

print(cowsay.get_output_string("cow", "multi-project-hub"))
