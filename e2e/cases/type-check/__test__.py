import cowsay

from shapes import area

total: int = area(2, 3)
assert total == 6
assert "type-check" in cowsay.get_output_string("cow", "type-check")
