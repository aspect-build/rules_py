import os

import annotated
import stubby

for module in (annotated, stubby):
    stub = os.path.splitext(module.__file__)[0] + ".pyi"
    assert not os.path.exists(stub), "type stub leaked into runfiles: " + stub

print(annotated.greeting(stubby.VALUE))
