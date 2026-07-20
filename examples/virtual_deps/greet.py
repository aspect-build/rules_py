import cowsay

def greet(x: str) -> str:
  return cowsay.get_output_string("cow", x)
