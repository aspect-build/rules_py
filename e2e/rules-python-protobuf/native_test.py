from native_greeting_pb2 import NativeGreeting

greeting = NativeGreeting(recipient="rules_py", times=2)
assert NativeGreeting.FromString(greeting.SerializeToString()) == greeting
