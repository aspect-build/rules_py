from importlib.metadata import distributions


matches = list(distributions(name="collision-metadata-shared"))
assert len(matches) == 1, [str(match.locate_file("")) for match in matches]
assert matches[0].metadata["Summary"] == "_metadata_suppressible_second"
