"""E2E test for concurrent venv creation.

This test verifies that the file-based locking mechanism prevents race
conditions when multiple processes try to create the same venv simultaneously.
"""
import asyncio
import subprocess
import sys
from pathlib import Path


async def run_binary(name: str, binary_path: str):
    """Run a binary asynchronously and capture result."""
    proc = await asyncio.create_subprocess_exec(
        binary_path,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    return name, proc.returncode, stdout.decode(), stderr.decode()


def test_concurrent_venv_creation():
    """Test that concurrent runs don't cause race conditions."""
    # Find the hello binary in runfiles
    binary_path = Path(__file__).parent / "hello"
    
    # Run multiple concurrent instances
    num_processes = 5
    
    async def run_test():
        processes = [
            run_binary(f"process_{i}", str(binary_path))
            for i in range(1, num_processes + 1)
        ]
        return await asyncio.gather(*processes)
    
    results = asyncio.run(run_test())
    
    # All processes should succeed
    failures = []
    for name, rc, stdout, stderr in results:
        if rc != 0 or stdout.strip() != "hello":
            failures.append({
                "name": name,
                "returncode": rc,
                "stdout": stdout,
                "stderr": stderr,
            })
    
    if failures:
        print("\n❌ Race condition detected! Some processes failed:", file=sys.stderr)
        for failure in failures:
            print(f"\n{failure['name']}:", file=sys.stderr)
            print(f"  Return code: {failure['returncode']}", file=sys.stderr)
            print(f"  Stdout: {failure['stdout']}", file=sys.stderr)
            print(f"  Stderr: {failure['stderr'][:200]}", file=sys.stderr)
        sys.exit(1)
    
    print(f"✅ All {num_processes} concurrent processes succeeded!")
    print("The venv locking mechanism prevented race conditions.")


if __name__ == "__main__":
    test_concurrent_venv_creation()