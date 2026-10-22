"""The hello application of the Python sample (tests/stacks)."""


def greet(name: str) -> str:
    """Return the greeting for name."""
    return f"Hello, {name}!"


if __name__ == "__main__":
    print(greet("world"))
