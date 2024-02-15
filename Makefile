build:
	cross build --release --target=x86_64-unknown-linux-musl
	cross build --release --target=aarch64-unknown-linux-musl
	cargo build --release
	cargo build --release --target=x86_64-apple-darwin

	cp target/x86_64-unknown-linux-musl/release/venv py/tools/venv_bin/bins/venv-x86_64-unknown-linux-musl
	cp target/x86_64-unknown-linux-musl/release/unpack py/tools/unpack_bin/bins/unpack-x86_64-unknown-linux-musl

	cp target/aarch64-unknown-linux-musl/release/venv py/tools/venv_bin/bins/venv-aarch64-unknown-linux-musl
	cp target/aarch64-unknown-linux-musl/release/unpack py/tools/unpack_bin/bins/unpack-aarch64-unknown-linux-musl

	cp target/release/venv py/tools/venv_bin/bins/venv-aarch64-apple-darwin
	cp target/release/unpack py/tools/unpack_bin/bins/unpack-aarch64-apple-darwin

	cp target/x86_64-apple-darwin/release/venv py/tools/venv_bin/bins/venv-x86_64-apple-darwin
	cp target/x86_64-apple-darwin/release/unpack py/tools/unpack_bin/bins/unpack-x86_64-apple-darwin
