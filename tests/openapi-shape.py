#!/usr/bin/env python3
"""Checks a JSON body, a request or a stubbed response, against one component schema of an OpenAPI
3.0 document.

    openapi-shape.py <document> <schema> <body>

Exits 1 naming every path where the body breaks the schema, and 2 when the schema, or any schema
it reaches, uses a keyword or format this check does not read, so a contract that starts using one
fails here instead of passing unchecked, whatever the body carries. Standard library only.
"""

import datetime
import json
import re
import sys

READ = {
    "$ref", "oneOf", "nullable", "type", "format", "required", "properties",
    "additionalProperties", "items", "pattern", "minLength", "maxLength", "enum",
    "x-extensible-enum",
}
SKIPPED = {"description", "title", "example", "x-enumNames"}
TYPES = {"object", "array", "string", "integer", "number", "boolean"}
OBJECT_ONLY = {"required", "properties", "additionalProperties"}
INT32 = (-(2**31), 2**31 - 1)


class Unread(Exception):
    pass


def resolve(document, ref):
    if not ref.startswith("#/"):
        raise Unread(f"$ref {ref} is outside the document")
    node = document
    for part in ref[2:].split("/"):
        if not isinstance(node, dict) or part not in node:
            raise Unread(f"$ref {ref} names nothing in the document")
        node = node[part]
    return node


def audit(document, schema, at, seen):
    """Refuses a schema this check would read only in part, before any value is looked at."""
    unknown = sorted(k for k in schema if k not in READ | SKIPPED)
    if unknown:
        raise Unread(f"{at}: the schema uses {', '.join(unknown)}, which this check does not read")
    kind = schema.get("type")
    if kind is not None and kind not in TYPES:
        raise Unread(f"{at}: type {kind}")
    for keyword in sorted(OBJECT_ONLY & schema.keys()):
        if kind != "object":
            raise Unread(f"{at}: {keyword} on a schema whose type is not object")
    if ("items" in schema) != (kind == "array"):
        raise Unread(f"{at}: items and type array must come together")
    if not isinstance(schema.get("additionalProperties", True), bool):
        raise Unread(f"{at}: additionalProperties is a schema")
    fmt = schema.get("format")
    # decimal is a string whose digits only the pattern beside it holds.
    if fmt is not None and not (
        fmt == "int32" and kind == "integer" or fmt == "decimal" and "pattern" in schema or fmt == "date" and kind == "string"
    ):
        raise Unread(f"{at}: format {fmt}")
    if "oneOf" in schema and len(schema["oneOf"]) != 1:
        raise Unread(f"{at}: oneOf with {len(schema['oneOf'])} members")
    children = [(member, f"{at}.{name}") for name, member in schema.get("properties", {}).items()]
    children += [(schema["items"], f"{at}[]")] if "items" in schema else []
    children += [(schema["oneOf"][0], at)] if "oneOf" in schema else []
    if "$ref" in schema and schema["$ref"] not in seen:
        seen.add(schema["$ref"])
        children.append((resolve(document, schema["$ref"]), schema["$ref"]))
    for child, child_at in children:
        audit(document, child, child_at, seen)


def is_date(value):
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
        return False
    try:
        datetime.date.fromisoformat(value)
    except ValueError:
        return False
    return True


def check(document, value, schema, at):
    parts = [resolve(document, schema["$ref"])] if "$ref" in schema else []
    parts += schema.get("oneOf", [])

    if value is None:
        if schema.get("nullable") is True:
            return []
        if parts:
            return [e for part in parts for e in check(document, value, part, at)]
        return [f"{at} is null but not nullable"]

    errors = [e for part in parts for e in check(document, value, part, at)]
    kind = schema.get("type")
    if kind == "object":
        if not isinstance(value, dict):
            return errors + [f"{at} is not an object"]
        properties = schema.get("properties", {})
        errors += [f"{at} lacks required {name}" for name in schema.get("required", []) if name not in value]
        for name, member in value.items():
            if name in properties:
                errors += check(document, member, properties[name], f"{at}.{name}")
            elif schema.get("additionalProperties", True) is False:
                errors.append(f"{at}.{name} is sent but not in the contract")
    elif kind == "array":
        if not isinstance(value, list):
            return errors + [f"{at} is not an array"]
        for index, item in enumerate(value):
            errors += check(document, item, schema["items"], f"{at}[{index}]")
    elif kind == "string" and not isinstance(value, str):
        return errors + [f"{at} is not a string"]
    elif kind == "integer" and (isinstance(value, bool) or not isinstance(value, int)):
        return errors + [f"{at} is not an integer"]
    elif kind == "number" and (isinstance(value, bool) or not isinstance(value, (int, float))):
        return errors + [f"{at} is not a number"]
    elif kind == "boolean" and not isinstance(value, bool):
        return errors + [f"{at} is not a boolean"]

    if schema.get("format") == "int32" and not INT32[0] <= value <= INT32[1]:
        errors.append(f"{at} {value} is outside int32")
    if schema.get("format") == "date" and not is_date(value):
        errors.append(f"{at} {json.dumps(value)} is not a date such as 2026-10-26")
    # The document marks an enum a request shares with a response as extensible, so clients
    # tolerate a value added later; the server still refuses one it does not know in a request,
    # and a response checked here is a stub the tests wrote, which has no reason to use an unlisted
    # value, so the list is closed here.
    for keyword in ("enum", "x-extensible-enum"):
        if keyword in schema and value not in schema[keyword]:
            errors.append(f"{at} {json.dumps(value)} is not one of {json.dumps(schema[keyword])}")
    if "pattern" in schema:
        if not isinstance(value, str):
            errors.append(f"{at} is not a string, which its pattern needs")
        elif not re.search(schema["pattern"], value):
            errors.append(f"{at} {json.dumps(value)} does not match {schema['pattern']}")
    # The document writes the API's not-empty rule for a list as minLength on the array, so it
    # counts items there as it counts characters on a string.
    for keyword, broken, word in (("minLength", int.__lt__, "shorter"), ("maxLength", int.__gt__, "longer")):
        if keyword in schema:
            if not isinstance(value, (str, list)):
                errors.append(f"{at} has no length, which its {keyword} needs")
            elif broken(len(value), schema[keyword]):
                errors.append(f"{at} is {word} than {schema[keyword]}")
    return errors


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        document = json.load(f)
    with open(argv[3], encoding="utf-8") as f:
        body = json.load(f)
    schemas = document.get("components", {}).get("schemas", {})
    if argv[2] not in schemas:
        print(f"{argv[1]} has no schema {argv[2]}", file=sys.stderr)
        return 2
    try:
        audit(document, schemas[argv[2]], argv[2], set())
        errors = check(document, body, schemas[argv[2]], argv[2])
    except Unread as unread:
        print(f"cannot check {argv[3]}: {unread}", file=sys.stderr)
        return 2
    for error in errors:
        print(f"{argv[3]}: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
