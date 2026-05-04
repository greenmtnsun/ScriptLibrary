#!/usr/bin/env python3
"""
Wrap a Splunk Dashboard Studio JSON definition into the on-disk SimpleXML v2
container that Splunk loads from $SPLUNK_HOME/etc/apps/<APP>/default/data/ui/views/.

Usage:
    wrap_studio.py <input.json> <output.xml>
"""
import json
import sys


def main(src: str, dst: str) -> None:
    with open(src, "r", encoding="utf-8") as f:
        definition = f.read().strip()
    # Fail loudly on invalid JSON before producing a broken view file
    json.loads(definition)
    # CDATA cannot contain "]]>"; defensively split it
    safe = definition.replace("]]>", "]]]]><![CDATA[>")
    out = (
        '<dashboard version="2" theme="dark">\n'
        '  <definition><![CDATA[\n'
        f"{safe}\n"
        '  ]]></definition>\n'
        '  <meta type="hiddenChrome"></meta>\n'
        '</dashboard>\n'
    )
    with open(dst, "w", encoding="utf-8") as f:
        f.write(out)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.stderr.write("usage: wrap_studio.py <input.json> <output.xml>\n")
        sys.exit(2)
    main(sys.argv[1], sys.argv[2])
