import pathlib
import re
import sys

STRING_OPEN = re.compile(r'(#*)("""|")')

def without_comments_and_strings(source):
    """Keep statement boundaries while hiding nested comments and Swift strings."""
    masked = list(source)
    index = 0

    def hide(start, end):
        for position in range(start, end):
            if masked[position] not in "\r\n":
                masked[position] = " "

    while index < len(source):
        start = index
        if source.startswith("//", index):
            end = source.find("\n", index)
            index = len(source) if end == -1 else end
        elif source.startswith("/*", index):
            index += 2
            depth = 1
            while index < len(source) and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
        else:
            opening = STRING_OPEN.match(source, index)
            if opening is None:
                index += 1
                continue
            hashes, quotes = opening.groups()
            index += len(opening.group())
            closing = quotes + hashes
            escape = "\\" + hashes
            while index < len(source):
                if source.startswith(escape, index):
                    index += len(escape) + 1
                elif source.startswith(closing, index):
                    index += len(closing)
                    break
                else:
                    index += 1
        hide(start, min(index, len(source)))
    return "".join(masked)


# Match imports after a newline or semicolon, including visibility and attributes.
IMPORTS = re.compile(
    r"(?:^|;)\s*"
    r"(?:(?:@\w+(?:\([^()]*\))?|public|internal|package|private|fileprivate)\s+)*"
    r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"`?([A-Za-z_][A-Za-z0-9_]*)`?",
    re.MULTILINE,
)


def imported_modules(source):
    # Swift accepts a leading BOM and all three newline spellings.
    source = source.removeprefix("\ufeff").replace("\r\n", "\n").replace("\r", "\n")
    return IMPORTS.findall(without_comments_and_strings(source))


def spi_imports(source):
    """The modules imported with an @_spi attribute, which opens a package's SPI surface."""
    source = source.removeprefix("\ufeff").replace("\r\n", "\n").replace("\r", "\n")
    return [match.group(1) for match in IMPORTS.finditer(without_comments_and_strings(source))
            if re.search(r"@_spi\b", match.group())]


# The query helper's server and executable never link the app's wiring, even if Shell were declared for them.
SHELL_FREE = {"Query", "ActivityQueryServer"}



def check_sources(target, modules, allowed, sources):
    forbidden = set(modules) - set(allowed)
    for source in sources:
        for module in imported_modules(pathlib.Path(source).read_text(encoding="utf-8")):
            if target == "Core" and module != "Foundation":
                raise ValueError(f"Core may import only Foundation; found {module}")
            if target in SHELL_FREE and module == "Shell":
                raise ValueError(f"{target} may not import Shell; the query helper stays out of the app's wiring")
            if module in forbidden:
                raise ValueError(
                    f"{target} may not import {module}; declare only permitted package dependencies"
                )




def main():
    target, modules, allowed, output, *sources = sys.argv[1:]
    try:
        check_sources(target, modules.split(","), allowed.split(","), sources)
    except ValueError as error:
        sys.exit(f"error: {error}")
    generated = pathlib.Path(output)
    generated.parent.mkdir(parents=True, exist_ok=True)
    generated.write_text("// Import boundary check passed. No declarations are generated.\n")


if __name__ == "__main__":
    main()
