import click

@click.command()
@click.option('--count', default=1)
def cli(count):
    click.echo(f"Count = {count}")

if __name__ == '__main__':
    cli()
