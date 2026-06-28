from importlib.metadata import distributions
import sys


distribution_name, expected_summary = sys.argv[1:3]
matches = list(distributions(name=distribution_name))
assert len(matches) == 1, [str(match.locate_file("")) for match in matches]
assert matches[0].metadata["Summary"] == expected_summary
