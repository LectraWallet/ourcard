#!/usr/bin/env python3
"""Generates OurCard.xcodeproj/project.pbxproj deterministically."""
import os

ROOT = os.path.dirname(os.path.abspath(__file__))

def nid(n):
    # 24-hex-char IDs, namespaced by counter
    return "%024X" % n

counter = [0x1000]
def new_id():
    counter[0] += 1
    return nid(counter[0])

# (path, kind)  kind: swift | objc | header | xcframework | plist | entitlements | bridghdr
FILES = [
    ("OurCard/OurCardApp.swift", "swift"),
    ("Exploit/AirliftBridge.swift", "swift"),
    ("Exploit/PairingManager.swift", "swift"),
    ("Exploit/GrappaHelper.h", "header"),
    ("Exploit/GrappaHelper.m", "objc"),
    ("Wallpaper/TendiesImporter.swift", "swift"),
    ("Wallpaper/DescriptorInjector.swift", "swift"),
    ("Wallpaper/PosterBoardDB.swift", "swift"),
    ("Card/CardSkinEngine.swift", "swift"),
    ("Pass/PassBuilder.swift", "swift"),
    ("Respring/NeoSpring.swift", "swift"),
    ("OurCard/Info.plist", "plist"),
    ("OurCard/OurCard.entitlements", "entitlements"),
    ("OurCard/OurCard-Bridging-Header.h", "bridghdr"),
    ("AirliftFFI.xcframework", "xcframework"),
]

file_refs = {}   # path -> (fr_id, bf_id or None)
build_files = []
for path, kind in FILES:
    fr = new_id()
    bf = new_id() if kind in ("swift", "objc", "xcframework") else None
    file_refs[path] = (fr, bf)
    if bf:
        build_files.append((path, kind, bf))

# Fixed structural IDs
ID_PROJECT = nid(0x1); ID_MAIN_GROUP = nid(0x2); ID_PRODUCTS_GROUP = nid(0x3)
ID_APP_GROUP = nid(0x4); ID_EXPLOIT_GROUP = nid(0x5); ID_WALLPAPER_GROUP = nid(0x6)
ID_CARD_GROUP = nid(0x7); ID_RESPRING_GROUP = nid(0x8); ID_FW_GROUP = nid(0x9)
ID_PASS_GROUP = nid(0x16)
ID_TARGET = nid(0xA)
ID_SRC_PHASE = nid(0xB); ID_FW_PHASE = nid(0xC); ID_RES_PHASE = nid(0xD); ID_EMBED_PHASE = nid(0xE)
ID_PROJ_CFGLIST = nid(0xF); ID_TGT_CFGLIST = nid(0x10)
ID_PROJ_DEBUG = nid(0x11); ID_PROJ_RELEASE = nid(0x12)
ID_TGT_DEBUG = nid(0x13); ID_TGT_RELEASE = nid(0x14)
ID_APP_PRODUCT_FR = nid(0x15)

def fr(path): return file_refs[path][0]
def bf(path): return file_refs[path][1]

def filetype(kind):
    return {"swift": "sourcecode.swift", "objc": "sourcecode.c.objc",
            "header": "sourcecode.c.h", "xcframework": "wrapper.xcframework",
            "plist": "text.plist.xml", "entitlements": "text.plist.entitlements",
            "bridghdr": "sourcecode.c.h"}[kind]

lines = []
A = lines.append
A("// !$*UTF8*$!")
A("{")
A("\tarchiveVersion = 1;")
A("\tclasses = {};")
A("\tobjectVersion = 56;")
A("\tobjects = {")

# PBXBuildFile
for path, kind, bid in build_files:
    name = os.path.basename(path)
    A(f"\t\t{bid} /* {name} in {'Sources' if kind in ('swift','objc') else 'Frameworks'} */ = {{isa = PBXBuildFile; fileRef = {fr(path)} /* {name} */; }};")
# embed uses a second build file for the xcframework
EMBED_BF = new_id()
A(f"\t\t{EMBED_BF} /* AirliftFFI.xcframework in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {fr('AirliftFFI.xcframework')} /* AirliftFFI.xcframework */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};")

# PBXFileReference
for path, kind in FILES:
    name = os.path.basename(path)
    extra = 'explicitFileType = wrapper.application; includeInIndex = 0; ' if False else ''
    A(f"\t\t{fr(path)} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {filetype(kind)}; path = \"{path}\"; sourceTree = \"<group>\"; }};")
A(f"\t\t{ID_APP_PRODUCT_FR} /* OurCard.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = OurCard.app; sourceTree = BUILT_PRODUCTS_DIR; }};")

# Groups
def group(gid, name, children, path=None):
    kids = ", ".join(f"{c} /* {n} */" for c, n in children)
    p = f'path = {path}; ' if path else ''
    A(f"\t\t{gid} /* {name} */ = {{isa = PBXGroup; children = ({kids}, ); {p}sourceTree = \"<group>\"; }};")

group(ID_MAIN_GROUP, "", [(ID_APP_GROUP, "OurCard"), (ID_FW_GROUP, "Frameworks"), (ID_PRODUCTS_GROUP, "Products")])
group(ID_APP_GROUP, "OurCard", [
    (fr("OurCard/OurCardApp.swift"), "OurCardApp.swift"),
    (fr("OurCard/Info.plist"), "Info.plist"),
    (fr("OurCard/OurCard.entitlements"), "OurCard.entitlements"),
    (fr("OurCard/OurCard-Bridging-Header.h"), "OurCard-Bridging-Header.h"),
    (ID_EXPLOIT_GROUP, "Exploit"), (ID_WALLPAPER_GROUP, "Wallpaper"),
    (ID_CARD_GROUP, "Card"), (ID_PASS_GROUP, "Pass"), (ID_RESPRING_GROUP, "Respring"),
])
group(ID_EXPLOIT_GROUP, "Exploit", [
    (fr("Exploit/AirliftBridge.swift"), "AirliftBridge.swift"),
    (fr("Exploit/PairingManager.swift"), "PairingManager.swift"),
    (fr("Exploit/GrappaHelper.h"), "GrappaHelper.h"),
    (fr("Exploit/GrappaHelper.m"), "GrappaHelper.m"),
])
group(ID_WALLPAPER_GROUP, "Wallpaper", [
    (fr("Wallpaper/TendiesImporter.swift"), "TendiesImporter.swift"),
    (fr("Wallpaper/DescriptorInjector.swift"), "DescriptorInjector.swift"),
    (fr("Wallpaper/PosterBoardDB.swift"), "PosterBoardDB.swift"),
])
group(ID_CARD_GROUP, "Card", [(fr("Card/CardSkinEngine.swift"), "CardSkinEngine.swift")])
group(ID_PASS_GROUP, "Pass", [(fr("Pass/PassBuilder.swift"), "PassBuilder.swift")])
group(ID_RESPRING_GROUP, "Respring", [(fr("Respring/NeoSpring.swift"), "NeoSpring.swift")])
group(ID_FW_GROUP, "Frameworks", [(fr("AirliftFFI.xcframework"), "AirliftFFI.xcframework")])
group(ID_PRODUCTS_GROUP, "Products", [(ID_APP_PRODUCT_FR, "OurCard.app")])

# Build phases
src_files = ", ".join(f"{bf(p)} /* {os.path.basename(p)} in Sources */" for p, k in FILES if k in ("swift", "objc"))
A(f"\t\t{ID_SRC_PHASE} /* Sources */ = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({src_files}, ); runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{ID_FW_PHASE} /* Frameworks */ = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({bf('AirliftFFI.xcframework')} /* AirliftFFI.xcframework in Frameworks */, ); runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{ID_RES_PHASE} /* Resources */ = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{ID_EMBED_PHASE} /* Embed Frameworks */ = {{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 10; files = ({EMBED_BF} /* AirliftFFI.xcframework in Embed Frameworks */, ); name = \"Embed Frameworks\"; runOnlyForDeploymentPostprocessing = 0; }};")

# Target
A(f"\t\t{ID_TARGET} /* OurCard */ = {{isa = PBXNativeTarget; buildConfigurationList = {ID_TGT_CFGLIST} /* Build configuration list for PBXNativeTarget \"OurCard\" */; buildPhases = ({ID_SRC_PHASE} /* Sources */, {ID_FW_PHASE} /* Frameworks */, {ID_RES_PHASE} /* Resources */, {ID_EMBED_PHASE} /* Embed Frameworks */, ); buildRules = (); dependencies = (); name = OurCard; productName = OurCard; productReference = {ID_APP_PRODUCT_FR} /* OurCard.app */; productType = \"com.apple.product-type.application\"; }};")

# Project
A(f"\t\t{ID_PROJECT} /* Project object */ = {{isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; TargetAttributes = {{ {ID_TARGET} = {{ CreatedOnToolsVersion = 16.0; }}; }}; }}; buildConfigurationList = {ID_PROJ_CFGLIST} /* Build configuration list for PBXProject \"OurCard\" */; compatibilityVersion = \"Xcode 16.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, ); mainGroup = {ID_MAIN_GROUP}; productRefGroup = {ID_PRODUCTS_GROUP} /* Products */; projectDirPath = \"\"; projectRoot = \"\"; targets = ({ID_TARGET} /* OurCard */, ); }};")

# Configurations
def xc(cid, name, settings):
    s = "; ".join(f"{k} = {v}" for k, v in settings.items()) + ";"
    A(f"\t\t{cid} /* {name} */ = {{isa = XCBuildConfiguration; buildSettings = {{{s}}}; name = {name}; }};")

xc(ID_PROJ_DEBUG, "Debug", {"ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu11", "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "SDKROOT": "iphoneos"})
xc(ID_PROJ_RELEASE, "Release", {"ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu11", "MTL_ENABLE_DEBUG_INFO": "NO", "SDKROOT": "iphoneos"})
tgt_common = {
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CODE_SIGN_ENTITLEMENTS": "OurCard/OurCard.entitlements",
    "CODE_SIGN_IDENTITY": '""', "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGNING_ALLOWED": "NO", "CODE_SIGNING_REQUIRED": "NO",
    "INFOPLIST_FILE": "OurCard/Info.plist",
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
    "PRODUCT_BUNDLE_IDENTIFIER": "com.ourcard.ourcard",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SWIFT_OBJC_BRIDGING_HEADER": "OurCard/OurCard-Bridging-Header.h",
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": '"1"',
}
xc(ID_TGT_DEBUG, "Debug", dict(tgt_common, **{"DEBUG_INFORMATION_FORMAT": "dwarf",
    "GCC_PREPROCESSOR_DEFINITIONS": '"$(inherited) DEBUG=1"'}))
xc(ID_TGT_RELEASE, "Release", dict(tgt_common, **{"DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
    "SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": '"-O"'}))
A(f"\t\t{ID_PROJ_CFGLIST} /* Build configuration list for PBXProject \"OurCard\" */ = {{isa = XCConfigurationList; buildConfigurations = ({ID_PROJ_DEBUG} /* Debug */, {ID_PROJ_RELEASE} /* Release */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")
A(f"\t\t{ID_TGT_CFGLIST} /* Build configuration list for PBXNativeTarget \"OurCard\" */ = {{isa = XCConfigurationList; buildConfigurations = ({ID_TGT_DEBUG} /* Debug */, {ID_TGT_RELEASE} /* Release */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")

A("\t};")
A(f"\trootObject = {ID_PROJECT} /* Project object */;")
A("}")

out = os.path.join(ROOT, "OurCard.xcodeproj")
os.makedirs(out, exist_ok=True)
with open(os.path.join(out, "project.pbxproj"), "w") as f:
    f.write("\n".join(lines) + "\n")
print("wrote", os.path.join(out, "project.pbxproj"))
