#!/usr/bin/env python3
"""Inventory public UYAP class/method names on a disposable CI runner.

No bytecode is decompiled, no implementation is printed, and no method is
invoked. This is a bounded discovery aid for locating the official document
reader/writer API used to produce canonical synthetic fixtures.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile


SOURCE = r'''
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;

public final class UYAPPublicAPIInventory {
    public static void main(String[] names) {
        for (String name : names) {
            try {
                Class<?> type = Class.forName(name, false, UYAPPublicAPIInventory.class.getClassLoader());
                System.out.println("ORACLE_CLASS " + name + " extends "
                    + (type.getSuperclass() == null ? "<none>" : type.getSuperclass().getName()));
                Constructor<?>[] constructors = type.getConstructors();
                Arrays.sort(constructors, Comparator.comparing(Constructor::toString));
                for (int i = 0; i < Math.min(4, constructors.length); i++) {
                    System.out.println("ORACLE_CONSTRUCTOR " + constructors[i].toGenericString());
                }
                List<Method> methods = new ArrayList<>();
                for (Method method : type.getDeclaredMethods()) {
                    if (!Modifier.isPublic(method.getModifiers())) continue;
                    String lower = method.getName().toLowerCase(java.util.Locale.ROOT);
                    if (lower.matches(".*(read|write|save|load|serialize|create|open|export|import|convert|insert|document|header|footer|table|page|content).*")) {
                        methods.add(method);
                    }
                }
                methods.sort(Comparator.comparing(Method::toString));
                for (int i = 0; i < Math.min(20, methods.size()); i++) {
                    System.out.println("ORACLE_METHOD " + methods.get(i).toGenericString());
                }
            } catch (Throwable error) {
                System.out.println("ORACLE_CLASS_UNRESOLVED " + name + " " + error.getClass().getName());
            }
        }
    }
}
'''


def score(name: str) -> int:
    base = name.rsplit(".", 1)[-1].lower()
    value = 0
    for word, weight in [("xml", 30), ("document", 25), ("writer", 22), ("reader", 20),
                         ("serializer", 20), ("udf", 18), ("editorkit", 16),
                         ("header", 6), ("footer", 6), ("table", 5), ("image", 4)]:
        if word in base:
            value += weight
    if "action" in base or "dialog" in base or "toolbar" in base:
        value -= 35
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java", default=os.environ.get("UYAP_TEST_JAVA"))
    parser.add_argument("--classpath", default=os.environ.get("UYAP_TEST_CLASSPATH"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=50)
    args = parser.parse_args()
    if not args.java or not args.classpath or not 1 <= args.limit <= 80:
        parser.error("Official CI runtime/classpath and a limit from 1 through 80 are required")
    names = set()
    jars = [Path(part) for part in args.classpath.split(os.pathsep)
            if Path(part).name.startswith("editor_lib") and Path(part).suffix == ".jar"]
    for jar in jars:
        with zipfile.ZipFile(jar) as archive:
            for name in archive.namelist():
                if (not name.endswith(".class") or "$" in name
                        or not re.match(r"(?:tr/com/havelsan/|com/hvl/|com/havelsan/)", name)):
                    continue
                qualified = name[:-6].replace("/", ".")
                if score(qualified) > 0:
                    names.add(qualified)
    selected = sorted(names, key=lambda name: (-score(name), name))[:args.limit]
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "candidate-classes.json").write_text(json.dumps(selected, indent=2) + "\n", encoding="utf-8")
    print("ORACLE_API_CANDIDATES " + json.dumps(selected, separators=(",", ":")), flush=True)
    if not selected:
        print("No matching public document API candidates were found")
        return 1
    with tempfile.TemporaryDirectory(prefix="uyap-api-inventory-") as temporary:
        root = Path(temporary)
        source = root / "UYAPPublicAPIInventory.java"
        source.write_text(SOURCE, encoding="utf-8")
        compile_result = subprocess.run(["javac", "--release", "8", "-encoding", "UTF-8", "-d", str(root), str(source)],
                                        capture_output=True, text=True, timeout=90, check=False)
        if compile_result.returncode:
            (args.output / "inventory-compile.log").write_text(compile_result.stdout + compile_result.stderr, encoding="utf-8")
            raise RuntimeError("Public API inventory helper did not compile")
        result = subprocess.run([args.java, "-Djava.awt.headless=true", "-cp", str(root) + os.pathsep + args.classpath,
                                 "UYAPPublicAPIInventory", *selected],
                                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90, check=False)
        output = result.stdout + result.stderr
        (args.output / "public-api.txt").write_text(output, encoding="utf-8")
        print(output, end="", flush=True)
        return result.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, zipfile.BadZipFile, subprocess.TimeoutExpired, RuntimeError) as error:
        print("Public API inventory failed: " + str(error))
        raise SystemExit(1)
