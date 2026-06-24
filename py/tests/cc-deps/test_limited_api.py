import limited_api_library

assert limited_api_library.add(2, 3) == 5, (
    "stable-ABI extension returned the wrong sum"
)
