import unittest

from app import make_greeting, render
from greeting_pb2 import Greeting


class GreetingTest(unittest.TestCase):
    def test_fields(self) -> None:
        greeting = make_greeting("world", 3)
        self.assertEqual(greeting.recipient, "world")
        self.assertEqual(greeting.times, 3)

    def test_round_trip(self) -> None:
        greeting = make_greeting("rules_py", 1)
        restored = Greeting.FromString(greeting.SerializeToString())
        self.assertEqual(greeting, restored)

    def test_render(self) -> None:
        self.assertEqual(render(make_greeting("a", 2)), "Hello, a!\nHello, a!")


if __name__ == "__main__":
    unittest.main()
