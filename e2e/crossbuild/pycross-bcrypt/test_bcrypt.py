#!/usr/bin/env python3
import bcrypt


def main() -> None:
    password = b"correct horse battery staple"
    hashed = bcrypt.hashpw(password, bcrypt.gensalt(rounds=4))
    # A hash must verify against the password it was made from, and reject a
    # different one — deterministic regardless of the random salt gensalt()
    # picks.
    assert bcrypt.checkpw(password, hashed) is True, "checkpw rejected the password that produced this hash"
    assert bcrypt.checkpw(b"wrong password", hashed) is False, "checkpw accepted the wrong password"
    print("OK")


if __name__ == "__main__":
    main()
