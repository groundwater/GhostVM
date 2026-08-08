#!/usr/bin/env python3

"""Validate the Ghostbox command catalog and generate its Swift representation."""

import argparse
import copy
import html
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CN_TEMPLATE_PATH = ROOT / "GHOSTBOX_CLI_TEMPLATE.md"
CR_TEMPLATE_PATH = ROOT / "GHOSTBOX_CR_CLI_TEMPLATE.md"
CATALOG_PATH = ROOT / "GHOSTBOX_CLI_COMMANDS.json"
API_DOCS_DIR = ROOT / "docs/ghostbox-api"
GENERATED_DIR = ROOT / "macOS/GhostTools/Sources/ghostbox/Generated"
GENERATED_CATALOG_PATH = GENERATED_DIR / "GhostboxCommandCatalog.generated.swift"
GENERATED_FIXTURES_PATH = GENERATED_DIR / "GhostboxCommandFixtures.generated.swift"
RUNTIME_HANDLER_DIR = ROOT / "macOS/GhostVMContainerRuntime/Ghostbox"
RUNTIME_METHOD_PATH = ROOT / "macOS/GhostVMKit/Containers/GhostboxDirectProtocol.swift"
EXPECTED_ENTRY_COUNT = 282
EXPECTED_RESOURCE_COUNT = 39
OVERRIDE_GROUP = "containerConfigOverride"
ACRONYMS = {
    "id": "ID",
    "oci": "OCI",
    "vmm": "VMM",
    "dns": "DNS",
    "cpus": "CPUs",
    "mib": "MiB",
    "uint64": "UInt64",
}
METHOD_ID_RE = re.compile(r"^[a-z][A-Za-z0-9]*\.[a-z][A-Za-z0-9]*$")
COMMAND_ID_RE = re.compile(
    r"^(?P<namespace>cn|cr):(?P<resource>[a-z][a-z0-9-]*):(?P<operation>[a-z][a-z0-9-]*)$"
)
NAMESPACES = {
    "cn": {
        "name": "containerization",
        "aliases": ["containerization"],
        "source": CN_TEMPLATE_PATH.name,
        "repository": "https://github.com/apple/containerization",
        "version": "0.40.1",
        "revision": "7800b4642171561c95b5f55500b19e5dce5acd45",
    },
    "cr": {
        "name": "container",
        "aliases": ["container"],
        "source": CR_TEMPLATE_PATH.name,
        "repository": "https://github.com/apple/container",
        "version": "1.2.0",
        "revision": "6e65319fe476ffe8db8ddaf828a537ed36fe2859",
    },
}
TEMPLATE_PATHS = {
    "cn": CN_TEMPLATE_PATH,
    "cr": CR_TEMPLATE_PATH,
}
APPLE_DOC_ROW_RE = re.compile(
    r"^\| <pre><code>(?P<signature>.+)</code></pre> \| "
    r"\[`(?P<symbol>.+)`\]\((?P<url>https://apple\.github\.io/containerization/.+)\) \|$"
)
COMPATIBILITY_REFERENCE_METHODS = {
    "dns.validate",
    "dns.resolvConf",
    "dns.nameservers",
    "dns.domain",
    "dns.searchDomains",
    "dns.options",
}
GHOSTVM_EXTENSION_METHODS = {
    "container.list",
    "dns.delete",
    "kernel.default",
    "kernel.installRecommended",
    "manager.close",
    "mount.delete",
    "mount.guestShare",
    "network.delete",
    "processConfig.delete",
    "readerStream.createProxy",
    "readerStream.attachProxy",
    "readerStream.closeProxy",
    "writer.createProxy",
    "writer.attachProxy",
    "writer.closeProxy",
    "terminal.createProxy",
    "terminal.attachProxy",
    "terminal.waitAttachedProxy",
    "terminal.closeProxy",
    "volume.create",
    "volume.list",
    "volume.inspect",
    "volume.mount",
    "volume.delete",
}
DEFAULT_OPTION_TYPE_OVERRIDES = {
    ("container", "copy-in", "--mode"): "file-permissions",
    ("interface", "nat-create", "--mtu"): "uint32",
    ("network", "vmnet-create", "--mode"): "network-mode",
    ("volume", "create", "--size"): "uint64",
    ("*", "*", "--memory"): "uint64",
    ("*", "*", "--memory-overhead"): "uint64",
    ("*", "*", "--rootfs-size"): "uint64",
}


class CatalogError(Exception):
    pass


def scan_atoms(text):
    atoms = []
    start = 0
    bracket_depth = 0
    for index, character in enumerate(text):
        if character == "[":
            bracket_depth += 1
        elif character == "]":
            bracket_depth -= 1
            if bracket_depth < 0:
                raise CatalogError(f"unbalanced brackets in {text!r}")
        elif character.isspace() and bracket_depth == 0:
            if start < index:
                atoms.append(text[start:index])
            start = index + 1
    if bracket_depth:
        raise CatalogError(f"unbalanced brackets in {text!r}")
    if start < len(text):
        atoms.append(text[start:])
    return atoms


def split_result(text):
    if " -> " in text:
        return text.split(" -> ", 1)
    if text.startswith("-> "):
        return "", text[3:]
    return text, None


def parse_value(expression):
    repeatable = expression.endswith("...")
    if repeatable:
        expression = expression[:-3]
    nullable = expression.endswith("|null")
    if nullable:
        expression = expression[:-5]

    if "=" in expression and not expression.startswith("="):
        left, right = expression.split("=", 1)
        left_value = parse_value(left)
        right_value = parse_value(right)
        name = f"{left_value['name']}={right_value['name']}"
        value_type = f"{left_value['type']}={right_value['type']}"
    else:
        reference = re.fullmatch(r"@<([^:>]+):([^>]+)>", expression)
        literal = re.fullmatch(r"<([^:>]+):([^>]+)>", expression)
        if reference:
            name = reference.group(1)
            value_type = f"reference:{name}"
        elif literal:
            name = literal.group(1)
            value_type = literal.group(2)
        else:
            raise CatalogError(f"unsupported value expression {expression!r}")

    if nullable:
        value_type += "?"
    return {"name": name, "type": value_type, "repeatable": repeatable}


def inferred_default_type(value):
    if value in ("true", "false"):
        return "bool"
    if re.fullmatch(r"(?:0|[1-9][0-9]*)", value):
        return "int"
    return "string"


def parsed_default(value, value_type):
    if value_type == "bool":
        return value == "true"
    if value_type == "int":
        return int(value)
    return value


def parse_option(atoms, index, required, outer_repeatable=False, group=None):
    option_atom = atoms[index]
    if "=" in option_atom:
        name, default = option_atom.split("=", 1)
        value_type = inferred_default_type(default)
        value = {"name": name[2:], "type": value_type, "repeatable": False}
        default = parsed_default(default, value_type)
        consumed = 1
    else:
        name = option_atom
        default = None
        if index + 1 >= len(atoms):
            raise CatalogError(f"option {name!r} has no value")
        value = parse_value(atoms[index + 1])
        consumed = 2
    option = {
        "names": [name],
        "type": value["type"],
        "required": required,
        "repeatable": outer_repeatable or value["repeatable"],
        "default": default,
    }
    if group:
        option["group"] = group
    return option, consumed


def parse_arguments(atoms, allow_override=False):
    positionals = []
    options = []
    option_groups = []
    index = 0
    while index < len(atoms):
        atom = atoms[index]
        if atom.startswith("["):
            outer_repeatable = atom.endswith("...")
            inner = atom[1:-4] if outer_repeatable else atom[1:-1]
            inner_atoms = scan_atoms(inner)
            if inner_atoms and inner_atoms[0].startswith("--"):
                option, consumed = parse_option(inner_atoms, 0, False, outer_repeatable)
                if consumed != len(inner_atoms):
                    raise CatalogError(f"unexpected optional argument content in {atom!r}")
                options.append(option)
            elif allow_override and inner == "<override:container-config-override>":
                option_groups.append(OVERRIDE_GROUP)
            else:
                value = parse_value(inner + ("..." if outer_repeatable else ""))
                positionals.append({
                    "name": value["name"],
                    "type": value["type"],
                    "required": False,
                    "repeatable": value["repeatable"],
                })
            index += 1
        elif atom.startswith("--"):
            option, consumed = parse_option(atoms, index, True)
            options.append(option)
            index += consumed
        else:
            value = parse_value(atom)
            positionals.append({
                "name": value["name"],
                "type": value["type"],
                "required": True,
                "repeatable": value["repeatable"],
            })
            index += 1
    return positionals, options, option_groups


def lower_camel(value, operation=False):
    parts = value.split("-")
    result = parts[0]
    for part in parts[1:]:
        result += ACRONYMS.get(part, part[:1].upper() + part[1:])
    if operation and len(parts) > 1 and parts[0] in ACRONYMS:
        result = parts[0] + result[len(parts[0]):]
    return result


def method_id(resource, operation):
    return f"{lower_camel(resource)}.{lower_camel(operation, operation=True)}"


def wire_method_id(namespace, resource, operation):
    if namespace == "cn" or resource == "volume":
        return method_id(resource, operation)
    resource_name = lower_camel(resource)
    return f"cr{resource_name[:1].upper()}{resource_name[1:]}.{lower_camel(operation, operation=True)}"


def result_type(expression):
    if expression is None:
        return "void"
    value = parse_value(expression)
    suffix = "[]" if value["repeatable"] else ""
    return value["type"] + suffix


def sample_for_type(value_type, name):
    base_type = value_type.removesuffix("?")
    if "=" in base_type:
        left_type, right_type = base_type.split("=", 1)
        left_name, right_name = name.split("=", 1)
        return f"{sample_for_type(left_type, left_name)}={sample_for_type(right_type, right_name)}"
    if base_type.startswith("reference:"):
        return f"@{base_type.removeprefix('reference:')}/example"
    if "|" in base_type:
        return base_type.split("|", 1)[0]
    if base_type == "bool":
        return "true"
    if base_type in {"int", "int32", "int64", "uint16", "uint32", "uint64"}:
        return "1"
    if base_type in {"host-url", "host-path"}:
        return "/tmp/example"
    if base_type in {"container-path", "container-url"}:
        return "/example"
    if base_type == "cidrv4":
        return "192.0.2.2/24"
    if base_type == "cidrv6":
        return "2001:db8::2/64"
    if base_type == "ipv4-address":
        return "192.0.2.1"
    if base_type == "ipv6-address":
        return "2001:db8::1"
    if base_type == "mac-address":
        return "02:00:00:00:00:01"
    if base_type == "file-permissions":
        return "0644"
    if base_type == "logger-level":
        return "info"
    if base_type == "linux-signal":
        return "SIGTERM"
    if base_type == "linux-capability":
        return "CAP_CHOWN"
    if base_type in {"oci-platform", "system-platform"}:
        return "linux/arm64"
    if base_type == "oci-descriptor-json":
        return '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:' + ("0" * 64) + '","size":0}'
    if base_type.startswith("oci-") or base_type in {
        "attached-filesystem-map",
        "container-statistics",
        "mount-runtime-options",
        "pod-volume-source",
        "virtiofs-layout",
    }:
        return "{}"
    if name in {"assignment", "key-value"}:
        return "key=value"
    return "example"


def minimal_argv(entry):
    argv = [entry["commandID"]]
    if entry["commandShape"] == "reference":
        receiver = entry["positionals"][0]
        argv.append(sample_for_type(receiver["type"], receiver["name"]))
        positionals = entry["positionals"][1:]
    else:
        positionals = entry["positionals"]
    for positional in positionals:
        if positional["required"]:
            argv.append(sample_for_type(positional["type"], positional["name"]))
    for option in entry["options"]:
        if option["required"]:
            argv.extend([option["names"][0], sample_for_type(option["type"], option["names"][0][2:])])
    return argv


def markdown_signatures(lines):
    signatures = []
    index = 0
    while index < len(lines):
        if not lines[index].startswith("ghostbox "):
            index += 1
            continue
        source_line = index + 1
        first = lines[index].strip()
        syntax_lines = [first]
        index += 1
        while index < len(lines):
            stripped = lines[index].strip()
            if not lines[index].startswith("    ") or not stripped:
                break
            if stripped.startswith(("--", "[--", "<", "@<", "[<", "->")):
                syntax_lines.append(stripped)
                index += 1
                continue
            break
        signatures.append((source_line, syntax_lines))
    return signatures


def source_signatures():
    signatures = {}
    for path in TEMPLATE_PATHS.values():
        lines = path.read_text(encoding="utf-8").splitlines()
        for _, syntax_lines in markdown_signatures(lines):
            command_start = normalized_markdown_start(syntax_lines[0])
            if command_start in signatures:
                raise CatalogError(f"duplicate source signature for {command_start!r}")
            signatures[command_start] = "\n".join(syntax_lines)
    return signatures


def apple_api_documentation():
    documentation = {}
    for path in sorted(API_DOCS_DIR.glob("*.md")):
        if path.name == "README.md":
            continue
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            match = APPLE_DOC_ROW_RE.fullmatch(line)
            if not match:
                continue
            signature = html.unescape(match.group("signature"))
            command_start = normalized_markdown_start(signature.splitlines()[0])
            if command_start in documentation:
                previous = documentation[command_start]
                raise CatalogError(
                    f"duplicate Apple API documentation for {command_start!r} in "
                    f"{previous['source']} and {path.relative_to(ROOT)}:{line_number}"
                )
            documentation[command_start] = {
                "symbol": html.unescape(match.group("symbol")),
                "url": html.unescape(match.group("url")),
                "source": f"{path.relative_to(ROOT)}:{line_number}",
            }
    return documentation


def enrich_catalog_help(catalog):
    enriched = copy.deepcopy(catalog)
    signatures = source_signatures()
    documentation = apple_api_documentation()
    command_starts = {command["commandStart"] for command in enriched["commands"]}

    missing_signatures = sorted(command_starts - signatures.keys())
    cn_command_starts = {
        command["commandStart"] for command in enriched["commands"] if command["namespace"] == "cn"
    }
    missing_documentation = sorted(cn_command_starts - documentation.keys())
    extra_documentation = sorted(documentation.keys() - command_starts)
    errors = [f"source signature is missing for {command}" for command in missing_signatures]
    errors.extend(f"Apple API documentation is missing for {command}" for command in missing_documentation)
    errors.extend(f"Apple API documentation has no catalog command for {command}" for command in extra_documentation)
    if errors:
        raise CatalogError("help metadata validation failed:\n" + "\n".join(f"- {error}" for error in errors))

    for command in enriched["commands"]:
        command_start = command["commandStart"]
        command["signature"] = signatures[command_start]
        if command["namespace"] == "cn":
            command["appleAPISymbol"] = documentation[command_start]["symbol"]
            command["appleDocumentationURL"] = documentation[command_start]["url"]
        else:
            command["appleAPISymbol"] = command["swiftSymbol"]
            command["appleDocumentationURL"] = command["documentationURL"]
    return enriched


def normalized_markdown_start(line):
    command_text, _ = split_result(line.removeprefix("ghostbox "))
    atoms = scan_atoms(command_text)
    if not atoms or not COMMAND_ID_RE.fullmatch(atoms[0]):
        raise CatalogError(f"invalid command signature {line!r}")
    return atoms[0]


def parse_override_options(lines):
    try:
        heading = lines.index("## Manager Container Allocation")
    except ValueError as error:
        raise CatalogError("manager allocation section is missing") from error
    options = []
    in_group = False
    for line in lines[heading + 1:]:
        stripped = line.strip()
        if stripped == "```text":
            in_group = True
            continue
        if in_group and stripped == "```":
            break
        if in_group and stripped.startswith("--"):
            atoms = scan_atoms(stripped)
            option, consumed = parse_option(atoms, 0, False, group=OVERRIDE_GROUP)
            if consumed != len(atoms):
                raise CatalogError(f"unexpected manager override syntax {stripped!r}")
            options.append(option)
    if not options:
        raise CatalogError("manager override option group is empty")
    return options


def cr_source_metadata():
    text = CR_TEMPLATE_PATH.read_text(encoding="utf-8")
    match = re.search(r"<!-- GHOSTBOX_CATALOG_METADATA\n(?P<json>.*?)\n-->", text, re.DOTALL)
    if not match:
        raise CatalogError("CR catalog metadata block is missing")
    try:
        values = json.loads(match.group("json"))
    except json.JSONDecodeError as error:
        raise CatalogError(f"CR catalog metadata is invalid: {error}") from error
    if not isinstance(values, list):
        raise CatalogError("CR catalog metadata must be an array")
    metadata = {}
    for value in values:
        if not isinstance(value, dict) or not isinstance(value.get("commandID"), str):
            raise CatalogError("CR catalog metadata contains an invalid entry")
        command_id = value["commandID"]
        if command_id in metadata:
            raise CatalogError(f"duplicate CR catalog metadata for {command_id}")
        metadata[command_id] = value
    return metadata


def build_catalog():
    cn_lines = CN_TEMPLATE_PATH.read_text(encoding="utf-8").splitlines()
    override_options = parse_override_options(cn_lines)
    cr_metadata = cr_source_metadata()
    commands = []
    for expected_namespace, path in TEMPLATE_PATHS.items():
        lines = path.read_text(encoding="utf-8").splitlines()
        for source_line, syntax_lines in markdown_signatures(lines):
            first_without_result, inline_result = split_result(syntax_lines[0])
            atoms = scan_atoms(first_without_result)
            if len(atoms) < 2 or atoms[0] != "ghostbox":
                raise CatalogError(f"invalid signature at {path.name}:{source_line}")
            command_id = atoms[1]
            command_match = COMMAND_ID_RE.fullmatch(command_id)
            if not command_match or command_match.group("namespace") != expected_namespace:
                raise CatalogError(f"invalid command ID at {path.name}:{source_line}")
            namespace = command_match.group("namespace")
            resource = command_match.group("resource")
            operation = command_match.group("operation")
            argument_atoms = atoms[2:]
            if argument_atoms and argument_atoms[0].startswith("@<"):
                receiver = parse_value(argument_atoms.pop(0))
                shape = "reference"
                receiver_positional = {
                    "name": receiver["name"],
                    "type": receiver["type"],
                    "required": True,
                    "repeatable": False,
                }
            else:
                shape = "static"
                receiver_positional = None

            result_expression = inline_result
            for continuation in syntax_lines[1:]:
                arguments, continuation_result = split_result(continuation)
                if arguments:
                    argument_atoms.extend(scan_atoms(arguments))
                if continuation_result is not None:
                    if result_expression is not None:
                        raise CatalogError(f"multiple results at {path.name}:{source_line}")
                    result_expression = continuation_result

            positionals, options, option_groups = parse_arguments(
                argument_atoms,
                allow_override=namespace == "cn",
            )
            for option in options:
                if option["default"] is not None:
                    option_name = option["names"][0]
                    option["type"] = DEFAULT_OPTION_TYPE_OVERRIDES.get(
                        (resource, operation, option_name),
                        DEFAULT_OPTION_TYPE_OVERRIDES.get(("*", "*", option_name), option["type"]),
                    )
            if receiver_positional:
                positionals.insert(0, receiver_positional)
            if option_groups:
                options.extend(dict(option) for option in override_options)
            if shape == "static" and positionals and positionals[0]["type"] == "name" and result_expression and result_expression.startswith("@<"):
                shape = "create"

            namespace_metadata = NAMESPACES[namespace]
            command = {
                "commandID": command_id,
                "methodID": wire_method_id(namespace, resource, operation),
                "namespace": namespace,
                "sourceKind": "direct",
                "aliases": [
                    f"{alias}:{resource}:{operation}" for alias in namespace_metadata["aliases"]
                ],
                "resource": resource,
                "operation": operation,
                "commandStart": normalized_markdown_start(syntax_lines[0]),
                "commandShape": shape,
                "positionals": positionals,
                "options": options,
                "resultType": result_type(result_expression),
                "minimalArgv": [],
                "source": path.name,
                "sourceLine": source_line,
            }
            if namespace == "cr":
                metadata = cr_metadata.get(command_id)
                if metadata is None:
                    raise CatalogError(f"CR source metadata is missing for {command_id}")
                for field in (
                    "sourceKind",
                    "swiftModule",
                    "swiftSymbol",
                    "swiftSource",
                    "documentationURL",
                ):
                    if not isinstance(metadata.get(field), str) or not metadata[field]:
                        raise CatalogError(f"CR source metadata field {field} is missing for {command_id}")
                    command[field] = metadata[field]
                if "methodID" in metadata:
                    command["methodID"] = metadata["methodID"]
            if option_groups:
                command["optionGroups"] = option_groups
            command["minimalArgv"] = minimal_argv(command)
            commands.append(command)

    extra_cr_metadata = sorted(cr_metadata.keys() - {command["commandID"] for command in commands})
    if extra_cr_metadata:
        raise CatalogError(f"CR source metadata has no command definitions: {extra_cr_metadata}")

    resources = sorted({command["resource"] for command in commands})
    return {
        "schemaVersion": 2,
        "sources": [path.name for path in TEMPLATE_PATHS.values()],
        "namespaces": NAMESPACES,
        "entryCount": len(commands),
        "resourceCount": len(resources),
        "resources": resources,
        "sharedOptionGroups": {OVERRIDE_GROUP: override_options},
        "commands": commands,
    }


def require(condition, message, errors):
    if not condition:
        errors.append(message)


def validate_metadata_list(values, label, errors, options=False):
    require(isinstance(values, list), f"{label} must be an array", errors)
    if not isinstance(values, list):
        return
    for index, value in enumerate(values):
        item_label = f"{label}[{index}]"
        require(isinstance(value, dict), f"{item_label} must be an object", errors)
        if not isinstance(value, dict):
            continue
        require(isinstance(value.get("type"), str) and bool(value.get("type")), f"{item_label}.type is invalid", errors)
        require(isinstance(value.get("required"), bool), f"{item_label}.required is invalid", errors)
        require(isinstance(value.get("repeatable"), bool), f"{item_label}.repeatable is invalid", errors)
        if options:
            names = value.get("names")
            require(isinstance(names, list) and bool(names), f"{item_label}.names is invalid", errors)
            if isinstance(names, list):
                require(all(isinstance(name, str) and name.startswith("--") for name in names), f"{item_label}.names contains an invalid option", errors)
            require("default" in value, f"{item_label}.default is missing", errors)
        else:
            require(isinstance(value.get("name"), str) and bool(value.get("name")), f"{item_label}.name is invalid", errors)


def validate_catalog(catalog):
    errors = []
    require(isinstance(catalog, dict), "catalog root must be an object", errors)
    if not isinstance(catalog, dict):
        return errors
    commands = catalog.get("commands")
    require(isinstance(commands, list), "commands must be an array", errors)
    if not isinstance(commands, list):
        return errors

    require(catalog.get("schemaVersion") == 2, "schemaVersion must be 2", errors)
    require(catalog.get("sources") == [path.name for path in TEMPLATE_PATHS.values()], "sources do not match the authoritative templates", errors)
    require(catalog.get("namespaces") == NAMESPACES, "namespaces metadata is invalid", errors)
    resources = {command.get("resource") for command in commands if isinstance(command, dict)}
    command_ids = [command.get("commandID") for command in commands if isinstance(command, dict)]
    method_ids = [command.get("methodID") for command in commands if isinstance(command, dict)]
    command_starts = [command.get("commandStart") for command in commands if isinstance(command, dict)]
    require(len(commands) == EXPECTED_ENTRY_COUNT, f"expected {EXPECTED_ENTRY_COUNT} commands, found {len(commands)}", errors)
    require(len(resources) == EXPECTED_RESOURCE_COUNT, f"expected {EXPECTED_RESOURCE_COUNT} resources, found {len(resources)}", errors)
    require(catalog.get("entryCount") == len(commands), "entryCount does not match commands", errors)
    require(catalog.get("resourceCount") == len(resources), "resourceCount does not match commands", errors)
    require(catalog.get("resources") == sorted(resources), "resources does not match the sorted command resources", errors)
    require(len(command_ids) == len(set(command_ids)), "command IDs are not unique", errors)
    require(len(method_ids) == len(set(method_ids)), "method IDs are not unique", errors)
    require(len(command_starts) == len(set(command_starts)), "command starts are not unique", errors)

    shared_groups = catalog.get("sharedOptionGroups")
    require(isinstance(shared_groups, dict), "sharedOptionGroups must be an object", errors)
    override_options = shared_groups.get(OVERRIDE_GROUP) if isinstance(shared_groups, dict) else None
    validate_metadata_list(override_options, f"sharedOptionGroups.{OVERRIDE_GROUP}", errors, options=True)

    for index, command in enumerate(commands):
        label = f"commands[{index}]"
        require(isinstance(command, dict), f"{label} must be an object", errors)
        if not isinstance(command, dict):
            continue
        method = command.get("methodID")
        command_id = command.get("commandID")
        namespace = command.get("namespace")
        resource = command.get("resource")
        operation = command.get("operation")
        shape = command.get("commandShape")
        argv = command.get("minimalArgv")
        command_match = COMMAND_ID_RE.fullmatch(command_id) if isinstance(command_id, str) else None
        require(command_match is not None, f"{label}.commandID is invalid", errors)
        require(namespace in NAMESPACES, f"{label}.namespace is invalid", errors)
        if command_match:
            require(command_match.group("namespace") == namespace, f"{label}.commandID namespace does not match", errors)
            require(command_match.group("resource") == resource, f"{label}.commandID resource does not match", errors)
            require(command_match.group("operation") == operation, f"{label}.commandID operation does not match", errors)
        require(isinstance(method, str) and bool(METHOD_ID_RE.fullmatch(method)), f"{label}.methodID is invalid", errors)
        require(isinstance(resource, str) and bool(resource), f"{label}.resource is invalid", errors)
        require(isinstance(operation, str) and bool(operation), f"{label}.operation is invalid", errors)
        if isinstance(method, str) and isinstance(namespace, str) and isinstance(resource, str) and isinstance(operation, str):
            require(method == wire_method_id(namespace, resource, operation), f"{label}.methodID does not match its namespace, resource, and operation", errors)
        require(command.get("sourceKind") in {"direct", "ghostvm-adapter"}, f"{label}.sourceKind is invalid", errors)
        aliases = command.get("aliases")
        require(isinstance(aliases, list) and bool(aliases), f"{label}.aliases is invalid", errors)
        if isinstance(aliases, list) and isinstance(namespace, str) and isinstance(resource, str) and isinstance(operation, str) and namespace in NAMESPACES:
            expected_aliases = [f"{alias}:{resource}:{operation}" for alias in NAMESPACES[namespace]["aliases"]]
            require(aliases == expected_aliases, f"{label}.aliases does not match its namespace", errors)
        require(command.get("source") == NAMESPACES.get(namespace, {}).get("source"), f"{label}.source is invalid", errors)
        if namespace == "cr":
            for field in ("swiftModule", "swiftSymbol", "swiftSource", "documentationURL"):
                require(isinstance(command.get(field), str) and bool(command.get(field)), f"{label}.{field} is invalid", errors)
        require(shape in {"static", "reference", "create"}, f"{label}.commandShape is invalid", errors)
        require(isinstance(command.get("resultType"), str) and bool(command.get("resultType")), f"{label}.resultType is invalid", errors)
        require(isinstance(command.get("sourceLine"), int) and command.get("sourceLine", 0) > 0, f"{label}.sourceLine is invalid", errors)
        validate_metadata_list(command.get("positionals"), f"{label}.positionals", errors)
        validate_metadata_list(command.get("options"), f"{label}.options", errors, options=True)
        require(isinstance(argv, list) and bool(argv), f"{label}.minimalArgv is invalid", errors)
        if isinstance(argv, list) and argv:
            require(argv[0] == command_id, f"{label}.minimalArgv does not start with its qualified command ID", errors)
            try:
                require(argv == minimal_argv(command), f"{label}.minimalArgv does not match required metadata", errors)
            except (CatalogError, KeyError, TypeError, ValueError) as error:
                errors.append(f"{label}.minimalArgv could not be validated: {error}")
        option_names = [name for option in command.get("options", []) if isinstance(option, dict) for name in option.get("names", [])]
        require(len(option_names) == len(set(option_names)), f"{label}.options contains duplicate names", errors)

        groups = command.get("optionGroups", [])
        require(isinstance(groups, list), f"{label}.optionGroups must be an array", errors)
        if OVERRIDE_GROUP in groups and isinstance(override_options, list):
            grouped = [option for option in command.get("options", []) if option.get("group") == OVERRIDE_GROUP]
            require(grouped == override_options, f"{label} does not contain the shared manager override options", errors)

    override_methods = {
        command.get("methodID")
        for command in commands
        if isinstance(command, dict) and OVERRIDE_GROUP in command.get("optionGroups", [])
    }
    require(
        override_methods == {
            "manager.createContainer",
            "manager.createContainerFromImage",
            "manager.createContainerFromMounts",
        },
        "shared manager overrides are not attached to exactly the three allocation commands",
        errors,
    )

    try:
        template_lines = {
            path.name: path.read_text(encoding="utf-8").splitlines()
            for path in TEMPLATE_PATHS.values()
        }
        markdown_commands = set()
        for lines in template_lines.values():
            markdown_commands.update(
                normalized_markdown_start(lines[source_line - 1])
                for source_line, _ in markdown_signatures(lines)
            )
        catalog_commands = set(command_starts)
        missing = sorted(markdown_commands - catalog_commands)
        extra = sorted(catalog_commands - markdown_commands)
        require(not missing, f"catalog is missing Markdown commands: {missing}", errors)
        require(not extra, f"catalog has commands absent from Markdown: {extra}", errors)
        for index, command in enumerate(commands):
            source = command.get("source") if isinstance(command, dict) else None
            source_line = command.get("sourceLine") if isinstance(command, dict) else None
            lines = template_lines.get(source, [])
            if isinstance(source_line, int) and 0 < source_line <= len(lines):
                require(lines[source_line - 1].startswith("ghostbox "), f"commands[{index}].sourceLine is not a signature", errors)
                if lines[source_line - 1].startswith("ghostbox "):
                    require(normalized_markdown_start(lines[source_line - 1]) == command.get("commandStart"), f"commands[{index}].sourceLine points to a different command", errors)
    except (CatalogError, OSError) as error:
        errors.append(f"could not compare Markdown command starts: {error}")
    return errors


def write_catalog(catalog):
    CATALOG_PATH.write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8")


def swift_string(value):
    if not isinstance(value, str) or not value.isascii():
        raise CatalogError(f"generated Swift string is not ASCII: {value!r}")
    return json.dumps(value)


def swift_json_value(value, value_type):
    if isinstance(value, bool):
        return f".boolean({str(value).lower()})"
    if isinstance(value, int):
        if value_type.removesuffix("?").startswith("uint"):
            return f".unsignedInteger({value})"
        return f".integer({value})"
    if isinstance(value, str):
        return f".string({swift_string(value)})"
    raise CatalogError(f"unsupported generated default {value!r}")


def positional_parameter_name(command, index, positional):
    method = command["methodID"]
    if method == "dns.create" and index == 0:
        return "name"
    if method in COMPATIBILITY_REFERENCE_METHODS and index == 0:
        return "reference"
    return lower_camel(positional["name"])


def render_swift_argument(command, index, argument):
    return (
        ".init("
        f"name: {swift_string(argument['name'])}, "
        f"parameterName: {swift_string(positional_parameter_name(command, index, argument))}, "
        f"type: {swift_string(argument['type'])}, "
        f"required: {str(argument['required']).lower()}, "
        f"repeatable: {str(argument['repeatable']).lower()}"
        ")"
    )


def option_parameter_name(command, option):
    compatibility_names = {
        ("dns.create", "--nameserver"): "nameservers",
        ("dns.create", "--search-domain"): "searchDomains",
        ("dns.create", "--option"): "options",
    }
    return compatibility_names.get(
        (command["methodID"], option["names"][0]),
        lower_camel(option["names"][0][2:]),
    )


def render_swift_option(command, option):
    names = ", ".join(swift_string(name) for name in option["names"])
    parameter_name = option_parameter_name(command, option)
    default = "nil"
    if option["default"] is not None:
        default = swift_json_value(option["default"], option["type"])
    return (
        ".init("
        f"names: [{names}], "
        f"parameterName: {swift_string(parameter_name)}, "
        f"type: {swift_string(option['type'])}, "
        f"required: {str(option['required']).lower()}, "
        f"repeatable: {str(option['repeatable']).lower()}, "
        f"defaultValue: {default}"
        ")"
    )


def render_swift_list(values, indent):
    if not values:
        return "[]"
    padding = " " * indent
    inner = (",\n" + padding).join(values)
    return f"[\n{padding}{inner},\n{' ' * (indent - 4)}]"


def render_catalog_swift(catalog):
    command_blocks = []
    for command in catalog["commands"]:
        positionals = render_swift_list(
            [render_swift_argument(command, index, value) for index, value in enumerate(command["positionals"])],
            12,
        )
        options = render_swift_list([render_swift_option(command, value) for value in command["options"]], 12)
        implicit_defaults = "[:]"
        if command["methodID"] == "dns.create":
            implicit_defaults = '["searchDomains": .array([]), "options": .array([])]'
        command_blocks.append(
            "    .init(\n"
            f"        commandID: {swift_string(command['commandID'])},\n"
            f"        methodID: {swift_string(command['methodID'])},\n"
            f"        namespace: {swift_string(command['namespace'])},\n"
            f"        sourceKind: {swift_string(command['sourceKind'])},\n"
            f"        aliases: {render_swift_list([swift_string(value) for value in command['aliases']], 12)},\n"
            f"        resource: {swift_string(command['resource'])},\n"
            f"        operation: {swift_string(command['operation'])},\n"
            f"        shape: .{command['commandShape']},\n"
            f"        signature: {swift_string(command['signature'])},\n"
            f"        resultType: {swift_string(command['resultType'])},\n"
            f"        appleAPISymbol: {swift_string(command['appleAPISymbol'])},\n"
            f"        appleDocumentationURL: {swift_string(command['appleDocumentationURL'])},\n"
            f"        swiftModule: {swift_string(command['swiftModule']) if 'swiftModule' in command else 'nil'},\n"
            f"        swiftSymbol: {swift_string(command.get('swiftSymbol', command['appleAPISymbol']))},\n"
            f"        swiftSource: {swift_string(command['swiftSource']) if 'swiftSource' in command else 'nil'},\n"
            f"        exampleArguments: {render_swift_list([swift_string(value) for value in command['minimalArgv']], 12)},\n"
            f"        positionals: {positionals},\n"
            f"        options: {options},\n"
            f"        implicitDefaults: {implicit_defaults}\n"
            "    )"
        )

    rendered_commands = ",\n".join(command_blocks)

    return f'''// Generated by scripts/generate-ghostbox-command-catalog.py. Do not edit.

enum GhostboxCommandShape: String, Sendable {{
    case `static`
    case create
    case reference
}}

struct GhostboxCommandArgument: Sendable {{
    let name: String
    let parameterName: String
    let type: String
    let required: Bool
    let repeatable: Bool
}}

struct GhostboxCommandOption: Sendable {{
    let names: [String]
    let parameterName: String
    let type: String
    let required: Bool
    let repeatable: Bool
    let defaultValue: GhostboxJSONValue?
}}

struct GhostboxCommandSignature: Sendable {{
    let commandID: String
    let methodID: String
    let namespace: String
    let sourceKind: String
    let aliases: [String]
    let resource: String
    let operation: String
    let shape: GhostboxCommandShape
    let signature: String
    let resultType: String
    let appleAPISymbol: String
    let appleDocumentationURL: String
    let swiftModule: String?
    let swiftSymbol: String
    let swiftSource: String?
    let exampleArguments: [String]
    let positionals: [GhostboxCommandArgument]
    let options: [GhostboxCommandOption]
    let implicitDefaults: [String: GhostboxJSONValue]
}}

let ghostboxCommandResources = {render_swift_list([swift_string(value) for value in catalog['resources']], 4)}

let ghostboxCommandCatalog: [GhostboxCommandSignature] = [
{rendered_commands},
]
'''


def render_fixtures_swift(catalog):
    fixtures = []
    for command in catalog["commands"]:
        argv = ", ".join(swift_string(value) for value in command["minimalArgv"])
        fixtures.append(
            "    .init("
            f"commandID: {swift_string(command['commandID'])}, "
            f"methodID: {swift_string(command['methodID'])}, "
            f"argv: [{argv}]"
            ")"
        )
    rendered_fixtures = ",\n".join(fixtures)
    return f'''// Generated by scripts/generate-ghostbox-command-catalog.py. Do not edit.

struct GhostboxCommandFixture: Sendable {{
    let commandID: String
    let methodID: String
    let argv: [String]
}}

let ghostboxCommandFixtures: [GhostboxCommandFixture] = [
{rendered_fixtures},
]
'''


def generated_outputs(catalog):
    return {
        GENERATED_CATALOG_PATH: render_catalog_swift(catalog),
        GENERATED_FIXTURES_PATH: render_fixtures_swift(catalog),
    }


def load_valid_catalog():
    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    errors = validate_catalog(catalog)
    if errors:
        raise CatalogError("catalog validation failed:\n" + "\n".join(f"- {error}" for error in errors))
    return catalog


def validate_runtime_coverage(catalog):
    method_pattern = re.compile(r'"([a-z][A-Za-z0-9]*\.[a-z][A-Za-z0-9]*)"')
    case_pattern = re.compile(
        r'^\s*case\s+(?P<labels>"[a-z][A-Za-z0-9]*\.[a-z][A-Za-z0-9]*"'
        r'(?:\s*,\s*"[a-z][A-Za-z0-9]*\.[a-z][A-Za-z0-9]*")*)\s*:',
        re.MULTILINE,
    )
    comparison_pattern = re.compile(
        r'method\.rawValue\s*(?:==|!=)\s*"([a-z][A-Za-z0-9]*\.[a-z][A-Za-z0-9]*)"'
    )
    runtime_methods = set()
    for path in sorted(RUNTIME_HANDLER_DIR.glob("*.swift")):
        source = path.read_text(encoding="utf-8")
        for match in case_pattern.finditer(source):
            runtime_methods.update(method_pattern.findall(match.group("labels")))
        runtime_methods.update(comparison_pattern.findall(source))
    declaration_pattern = re.compile(r'rawValue:\s*"([a-z][A-Za-z0-9]*\.[a-z][A-Za-z0-9]*)"')
    runtime_methods.update(declaration_pattern.findall(RUNTIME_METHOD_PATH.read_text(encoding="utf-8")))

    catalog_methods = {command["methodID"] for command in catalog["commands"]}
    missing_extensions = sorted(GHOSTVM_EXTENSION_METHODS - runtime_methods)
    missing = sorted(catalog_methods - runtime_methods)
    extra = sorted(runtime_methods - catalog_methods - GHOSTVM_EXTENSION_METHODS)
    if missing or extra or missing_extensions:
        errors = [f"runtime is missing method {method}" for method in missing]
        errors.extend(f"runtime declares non-catalog method {method}" for method in extra)
        errors.extend(f"runtime is missing GhostVM extension method {method}" for method in missing_extensions)
        raise CatalogError("runtime coverage validation failed:\n" + "\n".join(f"- {error}" for error in errors))
    return len(catalog_methods)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--generate", action="store_true", help="rebuild the JSON catalog and generated Swift sources from the templates")
    action.add_argument("--check", action="store_true", help="validate the authoritative templates, JSON catalog, and generated Swift sources")
    args = parser.parse_args()

    try:
        expected_catalog = build_catalog()
        errors = validate_catalog(expected_catalog)
        if errors:
            raise CatalogError("generated catalog validation failed:\n" + "\n".join(f"- {error}" for error in errors))
        if args.generate:
            catalog = expected_catalog
            write_catalog(catalog)
        else:
            catalog = load_valid_catalog()
            if catalog != expected_catalog:
                raise CatalogError(
                    "catalog validation failed:\n"
                    f"- {CATALOG_PATH.relative_to(ROOT)} is stale relative to the authoritative templates"
                )
        catalog_with_help = enrich_catalog_help(catalog)
        outputs = generated_outputs(catalog_with_help)
        if args.generate:
            GENERATED_DIR.mkdir(parents=True, exist_ok=True)
            for path, content in outputs.items():
                path.write_text(content, encoding="utf-8")
            print(
                f"generated {CATALOG_PATH.relative_to(ROOT)} and {len(outputs)} Swift files: "
                f"{len(catalog['commands'])} commands, {len(catalog['resources'])} resources"
            )
        else:
            stale = []
            for path, expected in outputs.items():
                try:
                    actual = path.read_text(encoding="utf-8")
                except FileNotFoundError:
                    stale.append(f"{path.relative_to(ROOT)} is missing")
                    continue
                if actual != expected:
                    stale.append(f"{path.relative_to(ROOT)} is stale")
            if stale:
                raise CatalogError("generated Swift validation failed:\n" + "\n".join(f"- {error}" for error in stale))
            runtime_method_count = validate_runtime_coverage(catalog)
            print(
                f"validated catalog, {len(outputs)} generated Swift files, and {runtime_method_count} runtime methods: "
                f"{len(catalog['commands'])} commands, {len(catalog['resources'])} resources"
            )
    except (CatalogError, json.JSONDecodeError, OSError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
