"""

"""

def _decode_file(ctx, content_path):
    out = ctx.execute(
        [
            Label("@tomltool//file:downloaded"),
            "-d",
            content_path
        ]
    )
    if out.return_code == 0:
        return json.decode(out.stdout)

toml = struct(
    decode_file = _decode_file
)
