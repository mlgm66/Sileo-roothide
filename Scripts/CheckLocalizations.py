#!/usr/bin/env python3

import collections
import json
import re
import subprocess
from pathlib import Path
from xml.etree import ElementTree


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sileo/Sileo"
LOCALES = ("Base", "zh-Hans", "zh-Hant")
TABLES = ("Localizable.strings", "Errors.strings", "Categories.strings", "InfoPlist.strings")
STRING = r'"((?:[^"\\]|\\.)*)"'
FORMAT = re.compile(r"%(?:(\d+)\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(hh|ll|[hlLqztj])?([@diuoxXfFeEgGaAcCsSpDU%])")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_plist(path):
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)


def load_strings(path):
    keys = re.findall(r"^\s*" + STRING + r"\s*=", path.read_text(), re.MULTILINE)
    duplicates = [key for key, count in collections.Counter(keys).items() if count > 1]
    require(not duplicates, f"{path}: 重复键 {duplicates}")
    values = load_plist(path)
    require(all(value.strip() for value in values.values()), f"{path}: 存在空译文")
    return values


def format_arguments(value):
    arguments = []
    next_position = 1
    for match in FORMAT.finditer(value):
        position, length, kind = match.groups()
        if kind == "%":
            continue
        position = int(position) if position else next_position
        arguments.append((position, (length or "") + kind))
        next_position = position + 1
    return sorted(arguments)


def check_plural_tables():
    tables = {locale: load_plist(RESOURCES / f"{locale}.lproj/Localizable.stringsdict") for locale in LOCALES}
    base = tables["Base"]
    for locale, table in tables.items():
        require(table.keys() == base.keys(), f"{locale}: 复数键不一致")
        for key, entry in table.items():
            variables = set(entry) - {"NSStringLocalizedFormatKey"}
            require(variables == set(base[key]) - {"NSStringLocalizedFormatKey"}, f"{locale}/{key}: 复数变量不一致")
            expanded = entry["NSStringLocalizedFormatKey"]
            for variable in variables:
                rule = entry[variable]
                value_type = rule["NSStringFormatValueTypeKey"]
                require(rule["NSStringFormatSpecTypeKey"] == "NSStringPluralRuleType", f"{locale}/{key}: 复数规则错误")
                require(value_type == base[key][variable]["NSStringFormatValueTypeKey"], f"{locale}/{key}: 复数参数类型不一致")
                require("other" in rule, f"{locale}/{key}: 缺少 other")
                marker = f"%#@{variable}@"
                require(marker in expanded, f"{locale}/{key}: 未引用复数变量 {variable}")
                expanded = expanded.replace(marker, "%" + value_type)
            baseline = base[key]["NSStringLocalizedFormatKey"]
            for variable in variables:
                baseline = baseline.replace(f"%#@{variable}@", "%" + base[key][variable]["NSStringFormatValueTypeKey"])
            require(format_arguments(expanded) == format_arguments(baseline), f"{locale}/{key}: 复数模板参数不一致")
    return base


def check_source_keys(base, plural):
    pattern = re.compile(r"String\s*\(\s*localizationKey:\s*" + STRING + r"(?:\s*,\s*type:\s*\.(\w+))?")
    count = 0
    for path in (ROOT / "Sileo").rglob("*.swift"):
        source = path.read_text()
        for match in pattern.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            if source.splitlines()[line - 1].lstrip().startswith("//"):
                continue
            raw_key, kind = match.groups()
            require(r"\(" not in raw_key, f"{path}:{line}: 动态插值不能作为翻译键")
            key = json.loads('"' + raw_key + '"')
            table = {"error": "Errors.strings", "categories": "Categories.strings"}.get(kind, "Localizable.strings")
            require(key in base[table] or (table == "Localizable.strings" and key in plural), f"{path}:{line}: {table} 缺少 {key}")
            count += 1
    for path in (ROOT / "Sileo").rglob("*.storyboard"):
        for element in ElementTree.parse(path).iter("userDefinedRuntimeAttribute"):
            if element.get("keyPath") == "localizableTitle":
                require(element.get("value") in base["Localizable.strings"], f"{path}: 标题资源缺失")
    for filename in ("GZIP.swift", "BZIP.swift", "XZ.swift", "ZSTD.swift"):
        source = (ROOT / "Sileo/Backend/Decompression" / filename).read_text()
        for key in re.findall(r"case\s+\w+\s*=\s*" + STRING, source):
            require(key in base["Errors.strings"], f"{filename}: 解压错误资源缺少 {key}")
    source = (ROOT / "Sileo/Backend/APT Wrapper/APTJsonParser.swift").read_text()
    conflict = re.search(r"enum Conflict: String, Decodable \{(.*?)var localizedDescription", source, re.DOTALL).group(1)
    for key in re.findall(r"^\s*case\s+\w+\s*=\s*" + STRING, conflict, re.MULTILINE):
        require(key in base["Localizable.strings"], f"依赖关系缺少 {key}")
    source = (ROOT / "Sileo/UI/Utils/SileoThemeManager.swift").read_text()
    for key in re.findall(r"SileoTheme\(name:\s*" + STRING, source):
        require(key in base["Localizable.strings"], f"内置主题缺少 {key}")
    fixture = (ROOT / "Sileo/Test Data/status").read_text()
    for category in set(re.findall(r"^Section:\s*(.+)$", fixture, re.MULTILINE)):
        require(category in base["Categories.strings"], f"分类缺少 {category}")
    return count


def check_system_resources(base):
    localized = base["InfoPlist.strings"]
    for path in (ROOT / "Sileo/Info.plist", ROOT / "Sileo Demo/Info.plist"):
        info = load_plist(path)
        require("NSFaceIDUsageDescription" in localized, f"{path}: Face ID 用途缺少译文")
        for shortcut in info.get("UIApplicationShortcutItems", []):
            require(shortcut["UIApplicationShortcutItemTitle"] in localized, f"{path}: 快捷菜单缺少译文")
        for document in info.get("CFBundleDocumentTypes", []):
            require(document["CFBundleTypeName"] in localized, f"{path}: 文档类型缺少译文")
        for declaration in info.get("UTImportedTypeDeclarations", []):
            require(declaration["UTTypeDescription"] in localized, f"{path}: 文件类型缺少译文")
    objects = load_plist(ROOT / "Sileo.xcodeproj/project.pbxproj")["objects"]
    groups = [(key, value) for key, value in objects.items() if value.get("isa") == "PBXVariantGroup" and value.get("name") == "InfoPlist.strings"]
    require(len(groups) == 1, "InfoPlist.strings 资源组缺失或重复")
    group_id, group = groups[0]
    require({objects[key]["name"] for key in group["children"]} == set(LOCALES), "系统文案的语言资源不齐")
    for target in objects.values():
        if target.get("productType") != "com.apple.product-type.application":
            continue
        resources = [objects[key] for key in target["buildPhases"] if objects[key]["isa"] == "PBXResourcesBuildPhase"]
        require(any(objects[key].get("fileRef") == group_id for phase in resources for key in phase["files"]), f'{target["name"]}: 未打包系统文案资源')


def main():
    catalogs = {locale: {table: load_strings(RESOURCES / f"{locale}.lproj" / table) for table in TABLES} for locale in LOCALES}
    base = catalogs["Base"]
    for locale in LOCALES[1:]:
        for table in TABLES:
            require(catalogs[locale][table].keys() == base[table].keys(), f"{locale}/{table}: 键集合不一致")
            for key, english in base[table].items():
                translated = catalogs[locale][table][key]
                require(format_arguments(english) == format_arguments(translated), f"{locale}/{table}/{key}: 格式参数不一致")
                require(translated != english or english in {"Sileo", "RootHide", "URL", "ID", "Filza", "X"}, f"{locale}/{table}/{key}: 仍保留英文原文")
    plural = check_plural_tables()
    calls = check_source_keys(base, plural)
    check_system_resources(base)
    print(f"本地化检查通过：{len(LOCALES)} 套语言，每套 {sum(map(len, base.values())) + len(plural)} 个键；核对 {calls} 处字面量调用。")


if __name__ == "__main__":
    main()
