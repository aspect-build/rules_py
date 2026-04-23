"""PEP-508 marker evaluation."""

load(":semver.bzl", "semver")

_VERSION_CMP = sorted(
    [
        i.strip(" '")
        for i in "'<' | '<=' | '!=' | '==' | '>=' | '>' | '~=' | '==='".split(" | ")
    ],
    key = lambda x: (-len(x), x),
)

_STATE = struct(
    STRING = "string",
    VAR = "var",
    OP = "op",
    NONE = "none",
)
_BRACKETS = "()"
_OPCHARS = "<>!=~"
_QUOTES = "'\""
_WSP = " \t"
_NON_VERSION_VAR_NAMES = [
    "implementation_name",
    "os_name",
    "platform_machine",
    "platform_python_implementation",
    "platform_release",
    "platform_system",
    "sys_platform",
    "extra",
]
_AND = "and"
_OR = "or"
_NOT = "not"
_ENV_ALIASES = "_aliases"

def tokenize(marker):
    """Tokenize a PEP 508 marker string.

    The output normalizes quoting to double quotes and trims all whitespace.
    The special token `not in` is collapsed into a single token.

    Args:
      marker: the marker string to tokenize.

    Returns:
      A list of token strings.
    """
    if not marker:
        return []

    tokens = []
    token = ""
    state = _STATE.NONE
    char = ""

    for _ in range(2 * len(marker)):
        if token and (state == _STATE.NONE or not marker):
            if tokens and token == "in" and tokens[-1] == _NOT:
                tokens[-1] += " " + token
            else:
                tokens.append(token)
            token = ""

        if not marker:
            return tokens

        char = marker[0]
        if char in _BRACKETS:
            state = _STATE.NONE
            token = char
        elif state == _STATE.STRING and char in _QUOTES:
            state = _STATE.NONE
            token = '"{}"'.format(token)
        elif (
            (state == _STATE.VAR and not char.isalnum() and char != "_") or
            (state == _STATE.OP and char not in _OPCHARS)
        ):
            state = _STATE.NONE
            continue
        elif state == _STATE.NONE:
            if char in _QUOTES:
                state = _STATE.STRING
            elif char.isalnum():
                state = _STATE.VAR
                token += char
            elif char in _OPCHARS:
                state = _STATE.OP
                token += char
            elif char in _WSP:
                state = _STATE.NONE
            else:
                fail("BUG: Cannot parse '{}' in {} ({})".format(char, state, marker))
        else:
            token += char

        marker = marker[1:]

    return fail("BUG: failed to process the marker in allocated cycles: {}".format(marker))

def evaluate(marker, *, env, strict = True, **kwargs):
    """Evaluate a PEP 508 marker against an environment dictionary.

    Args:
      marker: the marker string to evaluate.
      env:    dictionary of environment values.
      strict: if False, missing variables do not cause failure; instead the
              unevaluated sub-expression is returned as a string.
      **kwargs: extra arguments forwarded to the expression parser.

    Returns:
      True if the marker matches the environment, False otherwise.
      If strict is False and some variables are missing, may return a string
      representing the unevaluated expression.
    """
    tokens = tokenize(marker)
    ast = _new_expr(**kwargs)
    for _ in range(len(tokens) * 2):
        if not tokens:
            break

        tokens = ast.parse(env = env, tokens = tokens, strict = strict)

    if not tokens:
        return ast.value()

    fail("Could not evaluate: {}".format(marker))

_STRING_REPLACEMENTS = {
    "!=": "neq",
    "(": "_",
    ")": "_",
    "<": "lt",
    "<=": "lteq",
    "==": "eq",
    "===": "eeq",
    ">": "gt",
    ">=": "gteq",
    "not in": "not_in",
    "~==": "cmp",
}

def to_string(marker):
    """Convert a marker string into a normalized identifier."""
    return "_".join([
        _STRING_REPLACEMENTS.get(t, t)
        for t in tokenize(marker)
    ]).replace("\"", "")

def _and_fn(x, y):
    """Custom `and` evaluator supporting partial evaluation.

    When strict=False, unresolved sub-expressions remain as strings.
    If both operands are strings, they are concatenated with `and`.
    """
    if not (x and y):
        return False

    x_is_str = type(x) == type("")
    y_is_str = type(y) == type("")
    if x_is_str and y_is_str:
        return "{} and {}".format(x, y)
    elif x_is_str:
        return x
    else:
        return y

def _or_fn(x, y):
    """Custom `or` evaluator supporting partial evaluation.

    When strict=False, unresolved sub-expressions remain as strings.
    """
    x_is_str = type(x) == type("")
    y_is_str = type(y) == type("")

    if x_is_str and y_is_str:
        return "{} or {}".format(x, y) if x and y else ""
    elif x_is_str:
        return "" if y else x
    elif y_is_str:
        return "" if x else y
    else:
        return x or y

def _not_fn(x):
    """Custom `not` evaluator supporting partial evaluation."""
    if type(x) == type(""):
        return "not {}".format(x)
    else:
        return not x

def _new_expr(
        and_fn = _and_fn,
        or_fn = _or_fn,
        not_fn = _not_fn):
    """Create a new expression tree."""

    # buildifier: disable=uninitialized
    self = struct(
        tree = [],
        parse = lambda **kwargs: _parse(self, **kwargs),
        value = lambda: _value(self),
        current = lambda: self._current[0] if self._current else None,
        _current = [],
        _and = and_fn,
        _or = or_fn,
        _not = not_fn,
    )
    return self

def _parse(self, *, env, tokens, strict = False):
    """Parse the next token and return the remaining token list."""
    token, remaining = tokens[0], tokens[1:]

    if token == "(":
        expr = _open_parenthesis(self)
    elif token == ")":
        expr = _close_parenthesis(self)
    elif token == _AND:
        expr = _and_expr(self)
    elif token == _OR:
        expr = _or_expr(self)
    elif token == _NOT:
        expr = _not_expr(self)
    else:
        expr = marker_expr(env = env, strict = strict, *tokens[:3])
        remaining = tokens[3:]

    _append(self, expr)
    return remaining

def _value(self):
    """Evaluate the expression tree and return a boolean or string."""
    if not self.tree:
        return True

    for _ in range(len(self.tree)):
        if len(self.tree) == 1:
            return self.tree[0]

        if getattr(self.tree[-2], "op", None) == _OR:
            current = self.tree.pop()
            self.tree[-1] = self.tree[-1].value(current)
        else:
            break

    fail("BUG: invalid state: {}".format(self.tree))

def marker_expr(left, op, right, *, env, strict = True):
    """Evaluate a single marker comparison.

    Args:
      left:   the environment variable name or a quoted literal.
      op:     the comparison operator.
      right:  the environment variable name or a quoted literal.
      env:    dictionary of environment values.
      strict: if False, missing values return the unevaluated expression.

    Returns:
      A boolean result, or a string if the expression could not be evaluated.
    """
    var_name = None
    if right not in env and left not in env and not strict:
        return "{} {} {}".format(left, op, right)
    if left[0] == '"':
        var_name = right
        right = env[right]
        left = left.strip("\"")

        if _ENV_ALIASES in env:
            left = env.get(_ENV_ALIASES, {}).get(var_name, {}).get(left, left)
    else:
        var_name = left
        left = env[left]
        right = right.strip("\"")

        if _ENV_ALIASES in env:
            right = env.get(_ENV_ALIASES, {}).get(var_name, {}).get(right, right)

    if var_name in _NON_VERSION_VAR_NAMES:
        return _env_expr(left, op, right)
    elif var_name.endswith("_version"):
        return _version_expr(left, op, right)
    else:
        return False

def _env_expr(left, op, right):
    """Evaluate a string comparison expression."""
    if op == "==":
        return left == right
    elif op == "!=":
        return left != right
    elif op == "in":
        return left in right
    elif op == "not in":
        return left not in right
    else:
        return fail("TODO: op unsupported: '{}'".format(op))

def _version_expr(left, op, right):
    """Evaluate a version comparison expression using semver."""
    left = semver(left)
    right = semver(right)
    _left = left.key()
    _right = right.key()
    if op == "<":
        return _left < _right
    elif op == ">":
        return _left > _right
    elif op == "<=":
        return _left <= _right
    elif op == ">=":
        return _left >= _right
    elif op == "!=":
        return _left != _right
    elif op == "==":
        return _left[:3] == _right[:3]
    elif op == "~=":
        right_plus = right.upper()
        _right_plus = right_plus.key()
        return _left >= _right and _left < _right_plus
    elif op == "===":
        return _left == _right
    elif op in _VERSION_CMP:
        fail("TODO: op unsupported: '{}'".format(op))
    else:
        return False

def _append(self, value):
    if value == None:
        return

    current = self.current() or self
    op = getattr(value, "op", None)

    if op == _NOT:
        current.tree.append(value)
    elif op in [_AND, _OR]:
        value.append(current.tree[-1])
        current.tree[-1] = value
    elif not current.tree:
        current.tree.append(value)
    elif hasattr(current.tree[-1], "append"):
        current.tree[-1].append(value)
    else:
        current.tree._append(value)

def _open_parenthesis(self):
    """Push a new sub-expression node for parenthesized content."""
    self._current.append(_new_expr(
        and_fn = self._and,
        or_fn = self._or,
        not_fn = self._not,
    ))

def _close_parenthesis(self):
    """Pop and evaluate the current sub-expression node."""
    value = self._current.pop().value()
    if type(value) == type(""):
        return "({})".format(value)
    else:
        return value

def _not_expr(self):
    """Create a `not` expression node."""

    def _append(value):
        """Append a value to the `not` node, applying backtracking for precedence."""
        current = self.current() or self
        current.tree[-1] = self._not(value)

        for _ in range(len(current.tree)):
            if not len(current.tree) > 1:
                break

            op = getattr(current.tree[-2], "op", None)
            if op == None:
                pass
            elif op == _NOT:
                value = current.tree.pop()
                current.tree[-1] = self._not(value)
                continue
            elif op == _AND:
                value = current.tree.pop()
                current.tree[-1].append(value)
            elif op != _OR:
                fail("BUG: '{} not' compound is unsupported".format(current.tree[-1]))

            break

    return struct(
        op = _NOT,
        append = _append,
    )

def _and_expr(self):
    """Create an `and` expression node."""
    maybe_value = [None]

    def _append(value):
        """Append a value to the `and` node."""
        if maybe_value[0] == None:
            maybe_value[0] = value
            return

        current = self.current() or self
        current.tree[-1] = self._and(maybe_value[0], value)

    return struct(
        op = _AND,
        append = _append,
        _maybe_value = maybe_value,
    )

def _or_expr(self):
    """Create an `or` expression node."""
    maybe_value = [None]

    def _append(value):
        """Append a value to the `or` node."""
        if maybe_value[0] == None:
            maybe_value[0] = value
            return

        current = self.current() or self
        current.tree.append(value)

    return struct(
        op = _OR,
        value = lambda x: self._or(maybe_value[0], x),
        append = _append,
        _maybe_value = maybe_value,
    )
