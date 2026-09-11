import os

import annotated
import stubby

for module in (annotated, stubby):
    stub = os.path.splitext(module.__file__)[0] + ".pyi"
    assert os.path.exists(stub), "missing type stub next to " + module.__file__

print(annotated.greeting(stubby.VALUE))
